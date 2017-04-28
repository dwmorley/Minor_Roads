

-- To begin estimating the minor road importance index, the OSM data need to be 
-- split into individual AOIs, that is distinct networks of minor roads only accessible
-- to each other without a major road being crossed. Think of the holes a net pattern created by the 
-- major road network. Coastal areas are a special case, the minor road network is not encircled by major
-- roads in these areas. These areas have to be handled separately.


-- (1) Set up pgRouting
-- will give an error if exists (you can ignore this)
create extension pgrouting;
select pgr_version();


-- (2) Get the input data with topology enabled
-- 'tres' is the output from 'major_assignment.sql'
-- create a copy of tres first
create table pgr_gb as select * from tres;
create index pgr_gb_indx on pgr_gb using gist(geom);

-- create the topology
select pgr_createTopology('pgr_gb', 0.00001, 'geom', 'gid');


-- (3) Divide into minor and major road tables
-- table of major roads only (with AADT)
drop table if exists pgr_gb_major;
create table pgr_gb_major as
select * from pgr_gb as r
where minor = 0;
create index pgr_gb_major_indx on pgr_gb_major using gist(geom);

-- table of minor roads only
drop table if exists pgr_gb_minor;
create table pgr_gb_minor as
select * from pgr_gb as r
where minor = 1;
create index pgr_gb_minor_indx on pgr_gb_minor using gist(geom);


-- (4) Get bounding box of the road network
drop table if exists bbox;
create table bbox as
select st_extent(geom)::geometry as geom from tres;
select updategeometrysrid('bbox','geom',4326);


-- (5) Polygonise major road segments
-- This will give AOIs to generate routes within defined as
-- areas contained within a series of major roads
-- From one of these areas it is not possible to access a minor road
-- in another area without crossing a major road
drop table if exists major_polys_temp;
create table major_polys_temp as 
select st_buffer((st_dump(st_difference(b.geom, st_union(r.geom)))).geom, 0.001) as geom
from bbox as b, 
	(select st_buffer(m.geom, 0.001) as geom, m.gid
	from pgr_gb_major as m) as r
where st_intersects(b.geom, r.geom)
group by b.geom;
alter table major_polys_temp add column gid serial;


-- (6) First routing run is on closed polygons
-- Identify these as 'major_polys'
drop table if exists major_polys;
create table major_polys as 
select p.gid, p.geom from major_polys_temp as p where p.gid != 1;
alter table major_polys add column id serial;


-- (7) Second routing run is on parts of the network on the coast (i.e. not enclosed by major roads) or,
-- parts of the network on islands that have no major roads
-- Identify these as 'coast_roads' then assign them an ID based on groups, i.e. on basis of only being able to access
-- other minor roads without crossing a major road 'coast_roads_net'
drop table if exists major_poly_buf;
create table major_poly_buf as
select st_buffer(p.geom, 0.001) as geom
from major_polys as p;

drop table if exists coast_roads;
create table coast_roads as
select r.gid, r.geom, r.fclass
from pgr_gb_minor as r where not exists (select 1
	from (select distinct on (r.gid) r.gid from pgr_gb_minor as r, major_poly_buf as p
		where st_contains(p.geom, r.geom)) as ip
		where ip.gid = r.gid);

--collect groups of roads using dissolved buffer
drop table if exists coast_roads_grps;
create table coast_roads_grps as
select (st_dump(st_union(st_buffer(r.geom, 0.00001)))).geom as geom from
(select cr.gid, st_collectionextract(cr.geom, 2) as geom from coast_roads as cr) as r;
alter table coast_roads_grps add column id serial;
create index coast_roads_grps_indx on coast_roads_grps using gist(geom);

--assign group id to coastal roads
drop table if exists coast_roads_net;
create table coast_roads_net as
select r.gid, g.id, r.geom
from (select cr.gid, st_collectionextract(cr.geom, 2) as geom from coast_roads as cr) as r
inner join coast_roads_grps as g
on st_contains(g.geom, r.geom);

-- Data tables are now ready to be processed by pgRouting to estimate road importanrt index.
-- See 'minor_assignment_routing.sql'


