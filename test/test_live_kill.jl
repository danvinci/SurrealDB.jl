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
        conn.notification_channels[qid] = ch
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
        conn.notification_channels[qid] = ch
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
