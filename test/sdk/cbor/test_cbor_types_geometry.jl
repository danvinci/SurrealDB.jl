# L3 — Geometry hierarchy (tags 88-94).
# Refs: convert.rs:194-336 (decode), 457-509 (encode).

using SurrealDB.SurrealCBOR
using SurrealDB.SurrealCBOR: encode, decode, CBORError,
    GeometryPoint, GeometryLine, GeometryPolygon,
    GeometryMultiPoint, GeometryMultiLine, GeometryMultiPolygon,
    GeometryCollection,
    TAG_GEOMETRY_POINT, TAG_GEOMETRY_LINE, TAG_GEOMETRY_POLYGON,
    TAG_GEOMETRY_MULTIPOINT, TAG_GEOMETRY_MULTILINE,
    TAG_GEOMETRY_MULTIPOLYGON, TAG_GEOMETRY_COLLECTION
using Test

@testset "L3 Geometry (tags 88-94)" begin

    # Reusable fixtures
    p0 = GeometryPoint(0.0, 0.0)
    p1 = GeometryPoint(1.0, 1.0)
    p2 = GeometryPoint(2.0, 0.0)
    p3 = GeometryPoint(0.0, 2.0)
    line_unit  = GeometryLine([p0, p1])
    line_tri   = GeometryLine([p0, p2, p3, p0])  # closed
    polygon    = GeometryPolygon(line_tri)
    multi_pts  = GeometryMultiPoint([p0, p1, p2])
    multi_line = GeometryMultiLine([line_unit, line_tri])
    multi_poly = GeometryMultiPolygon([polygon, polygon])
    collection = GeometryCollection([p0, line_unit, polygon])

    @testset "Point" begin
        # Tag(88, [0.0, 0.0]) — both floats canonical-shrink to Float16
        # head = 0xd8 0x58; array[2] = 0x82; Float16(0.0) = 0xf9 0x00 0x00
        @test encode(p0) == UInt8[0xd8, 0x58, 0x82, 0xf9, 0x00, 0x00, 0xf9, 0x00, 0x00]
        @test decode(encode(p0)) == p0
        @test decode(encode(GeometryPoint(1.5, 2.5))) == GeometryPoint(1.5, 2.5)
    end

    @testset "Line" begin
        @test decode(encode(line_unit)) == line_unit
        @test decode(encode(line_tri)) == line_tri
        @test decode(encode(GeometryLine(GeometryPoint[]))) == GeometryLine(GeometryPoint[])
    end

    @testset "Polygon" begin
        @test decode(encode(polygon)) == polygon
        # With interior hole
        hole = GeometryLine([GeometryPoint(0.5, 0.5), GeometryPoint(1.0, 0.5),
                             GeometryPoint(0.75, 1.0), GeometryPoint(0.5, 0.5)])
        with_hole = GeometryPolygon(line_tri, [hole])
        @test decode(encode(with_hole)) == with_hole
    end

    @testset "MultiPoint / MultiLine / MultiPolygon" begin
        @test decode(encode(multi_pts))  == multi_pts
        @test decode(encode(multi_line)) == multi_line
        @test decode(encode(multi_poly)) == multi_poly
    end

    @testset "Collection (heterogeneous)" begin
        @test decode(encode(collection)) == collection
        # Empty collection
        @test decode(encode(GeometryCollection(Any[]))) == GeometryCollection(Any[])
        # Nested collection
        nested = GeometryCollection([p0, collection])
        @test decode(encode(nested)) == nested
    end

    @testset "Malformed payload errors" begin
        # Point with wrong array length
        @test_throws CBORError decode(UInt8[0xd8, 0x58, 0x81, 0x00])
        # Point with non-numeric coord
        bytes = vcat(UInt8[0xd8, 0x58, 0x82, 0x61], Vector{UInt8}(codeunits("x")), UInt8[0x00])
        @test_throws CBORError decode(bytes)
        # Line containing non-Point
        @test_throws CBORError decode(UInt8[0xd8, 0x59, 0x81, 0x01])
        # Empty polygon (must have >= 1 exterior ring)
        @test_throws CBORError decode(UInt8[0xd8, 0x5a, 0x80])
        # Collection containing non-Geometry
        @test_throws CBORError decode(UInt8[0xd8, 0x5e, 0x81, 0x01])
    end
end
