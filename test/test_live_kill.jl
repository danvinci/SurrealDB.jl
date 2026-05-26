# Unit tests for KILLED-frame dispatch — server-initiated kill must reach
# the subscriber; client-initiated kill drops silently.
#
# No server, no mock WS — exercises `_dispatch_live_notification` directly
# against a constructed RemoteWSConnection.

using SurrealDB
using Test

const _Lv = SurrealDB

@testset "client-initiated KILLED: channel gone → drop silently" begin
    conn = _Lv.RemoteConnection{:ws, :json}(url="ws://x")
    qid = "00000000-0000-0000-0000-000000000001"
    # Simulate state AFTER kill! has torn down the entry — channel + handle
    # already removed from the live-query Dicts. KILLED arriving now must
    # not surface as a phantom event; nothing to deliver to.
    @test !haskey(conn.notification_channels, qid)
    @test !haskey(conn.live_handles, qid)
    # Dispatch should silently return without throwing.
    @test _Lv._dispatch_live_notification(conn,
        Dict("id" => qid, "action" => "KILLED", "result" => nothing)) === nothing
end

@testset "server-initiated KILLED: subscriber notified + channel closed" begin
    conn = _Lv.RemoteConnection{:ws, :json}(url="ws://x")
    qid = "11111111-1111-1111-1111-111111111111"
    ch = Channel{Any}(8)
    sub = _Lv.LiveSubscription(qid, ch, nothing, true)
    lock(conn.live_lock) do
        conn.notification_channels[qid] = Channel[ch]
        conn.live_subscriptions[qid] = ("users", false)
        conn.live_handles[qid] = sub
    end

    # Server sends KILLED unprompted — subscriber's loop should observe it.
    _Lv._dispatch_live_notification(conn,
        Dict("id" => qid, "action" => "KILLED", "result" => nothing))

    # KILLED notification delivered.
    notif = take!(ch)
    @test notif isa _Lv.LiveNotification
    @test notif.action == "KILLED"
    # Channel closed → iteration ends.
    @test !isopen(ch)
    # Sub flagged inactive so external state inspectors see it.
    @test sub.active == false
    # All three live-query Dicts cleaned up.
    @test !haskey(conn.notification_channels, qid)
    @test !haskey(conn.live_subscriptions, qid)
    @test !haskey(conn.live_handles, qid)
end

@testset "non-KILLED action still routes to subscriber" begin
    # Regression guard: the KILLED branch must not swallow CREATE/UPDATE/DELETE.
    conn = _Lv.RemoteConnection{:ws, :json}(url="ws://x")
    qid = "22222222-2222-2222-2222-222222222222"
    ch = Channel{Any}(8)
    sub = _Lv.LiveSubscription(qid, ch, nothing, true)
    lock(conn.live_lock) do
        conn.notification_channels[qid] = Channel[ch]
        conn.live_subscriptions[qid] = ("users", false)
        conn.live_handles[qid] = sub
    end

    _Lv._dispatch_live_notification(conn,
        Dict("id" => qid, "action" => "CREATE", "result" => Dict("name" => "alice")))

    notif = take!(ch)
    @test notif.action == "CREATE"
    @test isopen(ch)  # CREATE doesn't tear down
    @test sub.active == true
end

@testset "multi-subscriber fan-out: every channel receives each notification" begin
    # Two channels registered against the same live UUID — both should see every
    # notification. Mirrors the JS `ManagedLiveQuery` Set-of-subscribers shape
    # (sdk-refs/js/.../utils/live.ts:84).
    conn = _Lv.RemoteConnection{:ws, :json}(url="ws://x")
    qid = "33333333-3333-3333-3333-333333333333"
    ch1 = Channel{Any}(8)
    ch2 = Channel{Any}(8)
    sub_primary = _Lv.LiveSubscription(qid, ch1, nothing, true)
    lock(conn.live_lock) do
        conn.notification_channels[qid] = Channel[ch1, ch2]
        conn.live_subscriptions[qid] = ("users", false)
        conn.live_handles[qid] = sub_primary
    end

    # CREATE fans out to both consumers.
    _Lv._dispatch_live_notification(conn,
        Dict("id" => qid, "action" => "CREATE", "result" => Dict("name" => "alice")))
    n1 = take!(ch1); n2 = take!(ch2)
    @test n1.action == "CREATE" && n2.action == "CREATE"
    @test isopen(ch1) && isopen(ch2)

    # Server-initiated KILLED fans out to both, then closes both channels.
    _Lv._dispatch_live_notification(conn,
        Dict("id" => qid, "action" => "KILLED", "result" => nothing))
    @test take!(ch1).action == "KILLED"
    @test take!(ch2).action == "KILLED"
    @test !isopen(ch1) && !isopen(ch2)
    @test sub_primary.active == false
    @test !haskey(conn.notification_channels, qid)
end

@testset "multi-subscriber fan-out: slow consumer doesn't starve peers" begin
    # If consumer A's channel fills up (or closes), consumer B should still
    # receive notifications. The dispatcher snapshots the subscriber vector
    # under the live_lock then iterates outside — a single full put! must
    # not block sibling deliveries.
    conn = _Lv.RemoteConnection{:ws, :json}(url="ws://x")
    qid = "44444444-4444-4444-4444-444444444444"
    ch_closed = Channel{Any}(1)
    close(ch_closed)  # A is already-closed → put! on it would throw
    ch_open = Channel{Any}(8)
    lock(conn.live_lock) do
        conn.notification_channels[qid] = Channel[ch_closed, ch_open]
        conn.live_subscriptions[qid] = ("users", false)
        conn.live_handles[qid] = _Lv.LiveSubscription(qid, ch_open, nothing, true)
    end

    # Dispatcher swallows the closed-channel error, B still receives.
    _Lv._dispatch_live_notification(conn,
        Dict("id" => qid, "action" => "UPDATE", "result" => Dict("v" => 1)))
    @test take!(ch_open).action == "UPDATE"
end

@testset "subscribe(sub) adds a second consumer on the same UUID" begin
    # Unit test for the public subscribe() API — direct registration via the
    # dispatch helper because the public function needs a live client/conn.
    # Verifies the registry shape supports the public-API contract.
    conn = _Lv.RemoteConnection{:ws, :json}(url="ws://x")
    qid = "55555555-5555-5555-5555-555555555555"
    ch1 = Channel{Any}(8)
    sub1 = _Lv.LiveSubscription(qid, ch1, nothing, true)
    lock(conn.live_lock) do
        conn.notification_channels[qid] = Channel[ch1]
        conn.live_subscriptions[qid] = ("users", false)
        conn.live_handles[qid] = sub1
    end

    # Simulate subscribe: append a fresh channel under the same UUID.
    ch2 = Channel{Any}(8)
    lock(conn.live_lock) do
        push!(conn.notification_channels[qid], ch2)
    end
    @test length(conn.notification_channels[qid]) == 2

    _Lv._dispatch_live_notification(conn,
        Dict("id" => qid, "action" => "CREATE", "result" => Dict("k" => "v")))
    @test take!(ch1).action == "CREATE"
    @test take!(ch2).action == "CREATE"
end
