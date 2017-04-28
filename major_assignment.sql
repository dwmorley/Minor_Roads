

-- The UK Dept of Transport AADT count points (CP) are on a slightly diffent geography to the OSM roads, 
-- this is possibly because they were georeferenced to the side of the road, pavement, or similar,
-- so the points do not intersect with the OSM road segments exactly.
-- To assign major road AADT to the OSM geography several steps are taken:
-- Initially CPs are assigned to the nearest OSM road segment where the road name matches (within 10m)
-- Individual OSM road segments representing this particualar road are then collected together using an iterative approach
-- Remaining roads are assigned CPs based on proximity, firstly nearest in 1km (if names match), secondly nearest in 1km (names do not have to match)
-- Note: the names field is often empty in both CP and OSM (usually A147 or similar, but often null)
-- Finally, the nearest CP in 10km is used as a last resort just to give a complete dataset


-- (1)THE INPUT DATA NEEDED

-- #######################################################
-- AADT on major roads from the UK Dept of Transport
-- imported as aadt_major_2013
-- convert to .dbf and use the PostGIS shapefile importer
-- #######################################################

--AADFYear	CP	Region	LocalA	Road	RoadCat	Direction	Easting	Northing	StartJu	EndJu	LinkLen	Linkmile	PedalCycle	twowheel	CarsTaxis	Buses	LightGood	AllHGVs	AllMV
--2013	51	South West	Isles of Scilly	A3111	PR	E	90200	10585	Pierhead, Hugh Town	A3112	0.3	0.2	149	51	298	13	182	22	566
--2013	51	South West	Isles of Scilly	A3111	PR	W	90200	10585	Pierhead, Hugh Town	A3112	0.3	0.2	136	42	229	14	144	16	445

--Make this a spatial table (assuming BNG:227700)
drop table if exists aadt_major_2013_pnts;
create table aadt_major_2013_pnts as
select 
	a.*,
	ST_SetSRID(ST_MakePoint(cast(a.Easting as numeric), cast(a.Northing as numeric)), 27700) as geom
from
	aadt_major_2013 as a;


-- #######################################################
-- OSM data as imported by osm2po (.bz2 file)
-- #######################################################

-- id integer NOT NULL,
-- osm_id bigint,
-- osm_name character varying,
-- osm_meta character varying,
-- osm_source_id bigint,
-- osm_target_id bigint,
-- clazz integer,
-- flags integer,
-- source integer,
-- target integer,
-- km double precision,
-- kmh integer,
-- cost double precision,
-- reverse_cost double precision,
-- x1 double precision,
-- y1 double precision,
-- x2 double precision,
-- y2 double precision,
-- geom_way geometry(LineString,4326)

-- #######################################################
-- OSM data as imported by shapefile (.shp file)
-- #######################################################

-- gid serial NOT NULL,
-- osm_id character varying(10),
-- code smallint,
-- fclass character varying(20),
-- name character varying(100),
-- ref character varying(20),
-- oneway character varying(1),
-- maxspeed smallint,
-- layer double precision,
-- bridge character varying(1),
-- tunnel character varying(1),
-- geom geometry(MultiLineString,4326)


-- (2) COMBINE THE GEOFABRIK DATA
-- As the geofabrik shp and bz have different attributes and we need a combination of both sets
-- that is, the route enabled dataset has different info to the shapefile, but the same geography
-- the first step is to combine these two files to one table

drop table if exists pgr_osm_wgs84_attr;
create table pgr_osm_wgs84_attr as
select 
	ox.source, ox.target, ox.geom_way as geom, ox.osm_id, ox.cost, ox.reverse_cost, 
	os.name, os.ref, os.fclass, os.oneway, os.bridge, os.tunnel, os.maxspeed
from 
	--roads is the .shp, hh_2po_4pgr is the .bz2 both download from geofabrik
	hh_2po_4pgr as ox left join roads as os 
	on ox.osm_id = cast(os.osm_id as bigint);

--add a new unique key	
alter table pgr_osm_wgs84_attr add column gid serial;


-- (3) SELECT ONLY THE MAJOR ROADS
-- Initially we only need the major roads to assign the known counts to
-- Here we use the 'fclass' attribute to select these and remove minor roads

drop table if exists osm_roads_major;
create table osm_roads_major as
select * 
	from pgr_osm_wgs84_attr as r
where 
	r.fclass = 'motorway' or
	r.fclass = 'motorway_link' or
	r.fclass = 'primary' or
	r.fclass = 'primary_link' or
	r.fclass = 'trunk' or
	r.fclass = 'trunk_link';  
	
create index osm_roads_major_indx on osm_roads_major using gist(geom);


-- (4) REPROJECT INTO LOCAL COORDINATE SYSTEM
-- Here we use BNG:27700
-- This matches the system used in the DfT count data set

drop table if exists osm_roads_major_bng;
create table osm_roads_major_bng as
select 
	st_transform(p.geom, 27700) as geom, p.name, p.ref, p.fclass, p.oneway, p.gid
from 
	osm_roads_major as p;
	
select updategeometrysrid('osm_roads_major_bng','geom',27700);
create index osm_roads_major_bng_indx on osm_roads_major_bng using gist(geom);


-- (5) CREATE THESE TWO FUNCTIONS BEFORE THE NEXT STEP
--
-- divide flow by 2 if a oneway segment
create or replace function oneway(ow character varying, q numeric)
returns numeric as $$
declare 
	result numeric;
begin
	if ow = '1' then
		result = q / 2;
	else
		result = q;
	end if;
	return result;
end
$$ language 'plpgsql' stable;

--nearest neighbour function
create or replace function  nn(nearto geometry, initialdistance real, distancemultiplier real, 
maxpower integer, nearthings text, nearthingsidfield text, nearthingsgeometryfield  text)
returns text as $$
declare 
  sql text;
  result text;
begin
  sql := ' select ' || quote_ident(nearthingsidfield) 
      || ' from '   || quote_ident(nearthings)
      || ' where st_dwithin($1, ' 
      ||   quote_ident(nearthingsgeometryfield) || ', $2 * ($3 ^ $4))'
      || ' order by st_distance($1, ' || quote_ident(nearthingsgeometryfield) || ')'
      || ' limit 1';
  for i in 0..maxpower loop
     execute sql into result using nearto             -- $1
				, initialdistance     -- $2
				, distancemultiplier  -- $3
				, i;                  -- $4
     if result is not null then return result; end if;
  end loop;
  return null;
end
$$ language 'plpgsql' stable;


-- (6) RUN THE ROUTINE TO ASSIGN OSM ROAD SEGEMENTS TO DfT COUNT POINTS
do $$ 
	-- some counters
	declare x integer;
	declare n integer;
	declare i integer;
begin 
	raise notice 'STARTING';

	-- Create the tables used to store results or temp data
	drop table if exists result;
	create table result (
		gid integer,
		near_cp integer
	);

	drop table if exists temp_result;
	create table temp_result (
		gid integer,
		near_cp integer
	);

	drop table if exists unassigned;
	create table unassigned (
		gid integer,
		name varchar,
		ref varchar,
		type varchar,
		geom geometry
	);
	create index unassigned_indx on unassigned using gist(geom);

	drop table if exists roads_with_cp;
	create table roads_with_cp (
		geom geometry,
		name varchar,
		ref varchar,
		gid integer,
		near_cp integer
	);
	create index roads_with_cp_indx on roads_with_cp using gist(geom);

	-- (A) Initial point assignment:
	-- get nearest AADT count points for each road (within 10m)
	drop table if exists point_to_road;
	create table point_to_road as
	select distinct on (np.geom) np.*, p.geom as cp_geom 
	from
		(select r.*, nn(r.geom, 1, 20, 2, 'aadt_major_2013_pnts', 'cp', 'geom') as near_cp
			from osm_roads_major_bng as r inner join aadt_major_2013_pnts as p
			on st_dwithin(p.geom, r.geom, 10)
		) as np 
			left join aadt_major_2013_pnts as p 
			on np.near_cp = p.cp;

	-- (B) Get the unassigned AADT count points
	-- These will be the ones that are >10m from a road
	drop table if exists unassigned_cp;
	create table unassigned_cp as
	select p.cp, p.road, p.geom from aadt_major_2013_pnts as p 
	where not exists (select 1 from
		point_to_road as a
		where a.near_cp = p.cp);
	create index unassigned_cp_indx on unassigned_cp using gist(geom);

	-- (C) also get all roads not assigned a cp from step (A)
	-- Note that this may seem a lot, but this is because a road feature may be of many
	-- individual segments. We will merge these later
	drop table if exists unassigned_cp_road;
	create table unassigned_cp_road as
	select r.* from osm_roads_major_bng as r
	where not exists (select 1 from
		point_to_road as a
		where a.gid = r.gid);

	-- (D) Match remaining count points that are further from roads (within 50m) but only if reference matches
	insert into point_to_road
	select distinct on (np.geom) np.*, p.geom as cp_geom 
	from
		(select r.*, nn(r.geom, 1, 20, 2, 'unassigned_cp', 'cp', 'geom') as near_cp
		from unassigned_cp_road as r inner join unassigned_cp as p
		on st_dwithin(p.geom, r.geom, 50)
		where p.road = r.ref 
		) as np 
		left join aadt_major_2013_pnts as p 
	on np.near_cp = p.cp;
	create index point_to_road_indx on point_to_road using gist(cp_geom);

	raise notice 'GOT NEAR CPs';

	-- (E) First round of assignment complete based on distance to road only
	-- Add these to the results table
	select count(r.*) from osm_roads_major_bng as r into n;
	raise notice 'NUMBER OF MAJOR ROADS: %', n;

	insert into result
	select p.gid, cast(p.near_cp as integer)
	from point_to_road as p;

	select count(r.*) from result as r into i;

	-- (F) Combine roads along segments according to ref (eg: A147) NOT name (eg: St. Crispins Road) 
	-- This collects the geoms together that represent a single road link usuall between two junctions
	raise notice 'STARTING LOOP';
	x := 1;

	while x > 0 loop

		raise notice 'X: %', x;

		-- Get the roads which still do not have a count assigned 
		truncate unassigned;
		insert into unassigned
		select r.gid, r.name, r.ref, r.fclass, r.geom
		from osm_roads_major_bng as r
		where not exists (select p.gid 
		from result as p
		where r.gid = p.gid);
			
		-- result is roads already assigned a cp from (E)
		insert into roads_with_cp
		(select r.geom, r.name, r.ref, f.gid, f.near_cp from result as f left join osm_roads_major_bng as r on f.gid = r.gid);

		-- join on the nearest road segements
		insert into temp_result
		select distinct on (nr.gid) nr.gid, nr.near_cp
		from
		(select t1.gid, t1.geom, t1.name, t1.ref, st_distance(a.geom, t1.geom) as dist, a.gid as agid, a.near_cp, a.ref as aref, a.name as aname
		from unassigned as t1, roads_with_cp as a
		where st_dwithin(a.geom, t1.geom, 25)	
		order by t1.gid, dist) as nr
		where (nr.ref = nr.aref); 

		-- store the results
		select count(u.*) from temp_result as u into x;
		insert into result select * from temp_result;

		truncate roads_with_cp;
		truncate temp_result;

	end loop;

	raise notice 'FINISHED LOOP';
	select count(r.*) from unassigned as r into n;
	raise notice 'UNASSIGNED ROAD SEGMENTS AFTER 1ST STEP: %', n;


	-- (G) Look for matching roads within 1km
	-- Only consider a match if the names match, e.g. A147 == A147
	-- Geographic proximity and attribute match
	raise notice 'SEARCHING FOR MATCHING CP, 1KM';
	
	-- unassigned roads
	truncate unassigned;
	insert into unassigned
	select r.gid, r.name, r.ref, r. fclass, r.geom
	from osm_roads_major_bng as r
	where not exists (select p.gid 
	from result as p
	where r.gid = p.gid);

	-- assigned roads
	insert into roads_with_cp
	(select r.geom, r.name, r.ref, f.gid, f.near_cp from result as f left join osm_roads_major_bng as r on f.gid = r.gid);

	-- look which unassigned roads are within 1km of an assigned (take the nearest if multiple)
	insert into temp_result
	select distinct on (nr.gid) nr.gid, nr.near_cp
	from
	(select t1.gid, t1.geom, t1.name, t1.ref, st_distance(a.geom, t1.geom) as dist, a.gid as agid, a.near_cp, a.ref as aref, a.name as aname
	from unassigned as t1, roads_with_cp as a
	where st_dwithin(a.geom, t1.geom, 1000)	
	order by t1.gid, dist) as nr
	where (nr.ref = nr.aref or nr.name = nr.aname); 

	-- store the results
	select count(u.*) from temp_result as u into x;
 	raise notice 'ROADS ASSIGNED IN 2ND STEP: %', x;
 	insert into result select * from temp_result;
 	truncate roads_with_cp;
 	truncate temp_result;


 	-- (F) Look for matching roads within 1km
	-- The condition on matching names is now removed
	-- This is because OSM or count point names attribute is often incomplete
	-- The match here is only based on geographic proximity
	raise notice 'SEARCHING FOR MATCHING CP, 1KM, IGNORE NAMES';

	-- unassigned roads
	truncate unassigned;
	insert into unassigned
	select r.gid, r.name, r.ref, r. fclass, r.geom
	from osm_roads_major_bng as r
	where not exists (select p.gid 
	from result as p
	where r.gid = p.gid);

	-- assigned roads
	insert into roads_with_cp
	(select r.geom, r.name, r.ref, f.gid, f.near_cp from result as f left join osm_roads_major_bng as r on f.gid = r.gid);

	-- look which unassigned roads are within 1km of an assigned (take the nearest if multiple)
	insert into temp_result
	select distinct on (nr.gid) nr.gid, nr.near_cp
	from
	(select t1.gid, t1.geom, t1.name, t1.ref, st_distance(a.geom, t1.geom) as dist, a.gid as agid, a.near_cp, a.ref as aref, a.name as aname
	from unassigned as t1, roads_with_cp as a
	where st_dwithin(a.geom, t1.geom, 1000)	
	order by t1.gid, dist) as nr; 

	-- store the results
	select count(u.*) from temp_result as u into x;
 	raise notice 'ROADS ASSIGNED IN 3RD STEP: %', x;
	insert into result select * from temp_result;
	truncate roads_with_cp;
	truncate temp_result;

 	-- (G) Look for matching roads within 10km
 	-- On geographic proximity only
 	raise notice 'SEARCHING FOR MATCHING CP, 10KM, IGNORE NAMES';

 	-- unassigned roads
	truncate unassigned;
	insert into unassigned
	select r.gid, r.name, r.ref, r. fclass, r.geom
	from osm_roads_major_bng as r
	where not exists (select p.gid 
	from result as p
	where r.gid = p.gid);

	-- assigned roads
	insert into roads_with_cp
	(select r.geom, r.name, r.ref, f.gid, f.near_cp from result as f left join osm_roads_major_bng as r on f.gid = r.gid);

	-- look which unassigned roads are within 10km of an assigned (take the nearest if multiple)
	insert into temp_result
	select distinct on (nr.gid) nr.gid, nr.near_cp
	from
	(select t1.gid, t1.geom, t1.name, t1.ref, st_distance(a.geom, t1.geom) as dist, a.gid as agid, a.near_cp, a.ref as aref, a.name as aname
	from unassigned as t1, roads_with_cp as a
	where st_dwithin(a.geom, t1.geom, 10000)	
	order by t1.gid, dist) as nr; 

	-- store the results
	select count(u.*) from temp_result as u into x;
	insert into result select * from temp_result;
	truncate roads_with_cp;
	truncate temp_result;


	-- (H) check for complete assignment
 	-- Should leave places such as Isle of Man and Channel Islands
	truncate unassigned;
	insert into unassigned
	select r.gid, r.name, r.ref, r. fclass, r.geom
	from osm_roads_major_bng as r
	where not exists (select p.gid 
	from result as p
	where r.gid = p.gid);
	select count(r.*) from unassigned as r into n;
	raise notice 'UNASSIGNED FINAL: %', n;


 	-- (I) Make final table
 	-- CP data is for 2-way traffic, if an OSM link is defined as oneway this needs to be split 
 	drop table if exists tres;
	create table tres as 
	select distinct on (t2.gid) t1.name, t1.ref, t1.geom, t1.oneway, t1.bridge, t1.tunnel, t1.maxspeed, t1.fclass, 
	t1.cost, t1.reverse_cost, t1.source, t1.target,
	oneway(t1.oneway, cast(t2.pedalcycle as numeric)) as pedalcycle, 
	oneway(t1.oneway, cast(t2.twowheel as numeric)) as twowheel, 
	oneway(t1.oneway, cast(t2.carstaxis as numeric)) as carstaxis, 
	oneway(t1.oneway, cast(t2.buses as numeric)) as buses, 
	oneway(t1.oneway, cast(t2.lightgood as numeric)) as lightgood, 
	oneway(t1.oneway, cast(t2.allhgvs as numeric)) as allhgvs, 
	oneway(t1.oneway, cast(t2.allmv as numeric)) as allmv,
	t2.cp, t2.gid, t1.minor
	from	
		(select r.name, r.ref, r.geom, r.oneway, r.bridge, r.tunnel, r.maxspeed, r. fclass, 
		r.cost, r.reverse_cost, r.source, r.target, f.gid, 0 as minor from result as f 
		left join pgr_osm_wgs84_attr as r on f.gid = r.gid) as t1 
	left join
		(select p.pedalcycle, p.twowheel, p.carstaxis, p.buses, p.lightgood, p.allhgvs, p.allmv, p.cp, f.gid from result as f 
	left join 
		aadt_major_2013_pnts as p on cast(p.cp as integer) = f.near_cp) as t2
	on t1.gid = t2.gid
	--add back minor roads
	union all
	select m.name, m.ref, m.geom, m.oneway, m.bridge, m.tunnel, m.maxspeed, m. fclass, 
	m.cost, m.reverse_cost, m.source, m.target,
	null as pedalcycle,
	null as twowheel,
	null as carstaxis,
	null as buses,
	null as lightgood,
	null as allhgvs,
	null as allmv,
	null as cp, 
	m.gid, 1 as minor
	from
		(select * from pgr_osm_wgs84_attr as r
		where 
		r. fclass != 'motorway' and
		r. fclass != 'motorway_link' and
		r. fclass != 'primary' and
		r. fclass != 'primary_link' and
		r. fclass != 'trunk' and
		r. fclass != 'trunk_link') as m;  

	-- (J) The table 'tres' has all major roads assigned AADT data
	-- Minor roads do not have any AADT data yet: see 'minor_assignment_dataprep.sql'
	-- 'tres' will be used as an input here

end $$;