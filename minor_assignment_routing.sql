
-- The pgRouting Dijkstra algorithm is run here
-- There are two runs: the major road enclosed minor roads and the coastal minor roads
-- The output is a table of all minor road IDs and a count of the number of times they are 
-- traversed. The results are then used in the next step (minor_assignment_index,sql)
-- to standardise these counts to a comparable index


-- (1) Create function to run Dijkstra algorithm
-- Counts how many times an edge is transversed
create or replace function get_path(s integer)
returns double precision as $$
declare 

begin
	truncate paths;
	insert into paths
	select seq, id1 as path, id2 as node, id3 as edge, cost
	from pgr_kdijkstrapath(
		'select gid as id, source, target, cost, reverse_cost from pgr_gb',
		s, array(select t.target from target as t), false, true 
		);
		
	update totals as t2
	set total = total + s.count
	from (select p.edge, count(p.edge)
	from paths as p group by p.edge) as s
	where  t2.gid = s.edge;

	return 1;
end
$$ language 'plpgsql' volatile;


-- (2) Create results/temp tables
drop table if exists poly;
create table poly (
	gid integer,
	geom_buf geometry,
	ring geometry,
	geom geometry
);
drop table if exists polyroads_all;
create table polyroads_all (
	source integer,
	target integer,
	geom geometry,
	gid integer,
	bridge character varying(1),
	tunnel character varying(1)
);
drop table if exists candidates;
create table candidates (
	gid integer,
	src_id integer,
	trg_id integer,
	src geometry,
	trg geometry,
	geom geometry
);

drop table if exists target;
create table target (
	target integer
);

drop table if exists source;
create table source (
	source integer
);

--input, output tables
drop table if exists paths;
create table paths (
	seq integer,
	path integer,
	node integer,
	edge integer,
	cost double precision
);

--Stores the final counts
drop table if exists totals;
create table totals as
select gid, 0 as total
from pgr_gb;


----------------------------------------------------------
-- (3) Run routing for enclosed polygons
----------------------------------------------------------
do $$ 
	declare polys integer[];
	declare x integer;
	declare x1 integer := 1;
	declare c1 integer;
	declare c2 integer;
begin 
	-- Get a list of the major road enclosed areas of minor road networks to process
	polys := array(select distinct gid from major_polys);

	truncate polyroads_all;
	truncate candidates;
	truncate target;
	truncate source;
	truncate paths;

	drop table if exists poly_count_area;
	create table poly_count_area (
		poly_id integer,
		n integer
	);

	foreach x in array polys loop
		raise notice 'POLYGON %: %', x, x1;

		--get major road polygon
		truncate poly;
		insert into poly
		select p.gid, st_buffer(p.geom, 0.0001) as geom_buf,
		st_exteriorring(p.geom) as ring, p.geom as geom
		from major_polys as p where p.gid = x
		and st_geometrytype(p.geom) = 'ST_Polygon'; 

		--get minor roads inside polygon
		truncate polyroads_all;
 		insert into polyroads_all
		select r.source, r.target, r.geom, r.gid, r.bridge, r.tunnel
		from poly as p,	(select * from pgr_gb as m where m.minor = 1) as r
		where st_intersects(p.geom_buf, r.geom);

 		--get canditate source and targets points
		truncate candidates;
		insert into candidates
		select r.gid, r.source as src_id, r.target as trg_id,
		st_startpoint(r.geom) as src, st_endpoint(r.geom) as trg,
		r.geom as geom
		from polyroads_all as r;

		--unique targets
		truncate target;
 		insert into target	
		with roads as (	
			select c.gid, c.geom, c.src_id, c.trg_id 
			from candidates as c, poly as p
			where st_contains(p.geom, c.geom)
		)
		select distinct on (t.target) t.target from
		(select r.trg_id as target from roads as r
		union all
		select r.src_id as target from roads as r) as t;

		truncate source;
		insert into source		
			select distinct on (sr.src_id) sr.src_id from
			(select c.src_id as src_id, c.src
			from candidates as c, poly as p
			where st_dwithin(c.src, p.ring, 0.0001) and st_contains(p.geom, c.trg)
			union all
		select c.trg_id as src_id, c.trg
			from candidates as c, poly as p
			where st_dwithin(c.trg, p.ring, 0.0001) and st_contains(p.geom, c.src)) as sr;

		--ensure all sources are also targets		
		insert into target
		select s.source
		from source as s 
		where not exists (select t.target
		from target as t where t.target = s.source);

		--remove sources that are bridges or tunnels
		delete from source using (
			select s.source
			from source as s inner join polyroads_all as p
			on s.source = p.gid
			where p.bridge = '1' or p.tunnel = '1') as remove
		where remove.source = source.source;

		--number of targets per poly
		insert into poly_count_area (select x, count(*) from target); 
	
		--run pgr_kdijkstrapath routing
		select count(*) from source into c1;
		select count(*) from target into c2;
		if c1 != 0 and c2 != 0 then
			perform get_path(s.source) from source as s;
		end if;
		x1 := x1 + 1;
	end loop;
end $$


----------------------------------------------------------
-- (4) Run routing for coastal areas
----------------------------------------------------------
do $$ 
	declare groups integer[];
	declare x integer;
	declare c1 integer;
	declare c2 integer;
begin 
	groups := array(select distinct id from coast_roads_grps);

	truncate polyroads_all;
	truncate candidates;
	truncate target;
	truncate source;
	truncate paths;

	drop table if exists poly_count_coast;
	create table poly_count_coast (
		poly_id integer,
		n integer
	);

	foreach x in array groups loop
		raise notice 'GROUP %', x;

		--get roads inside polygon
		truncate polyroads_all;
 		insert into polyroads_all
		select r.source, r.target, (st_dump(r.geom)).geom as geom, r.gid, r.bridge, r.tunnel
		from pgr_gb as r inner join coast_roads_net as p
		on r.gid = p.gid
		where p.id = x;

 		--get canditate source and targets
		truncate candidates;
		insert into candidates
		select r.gid, r.source as src_id, r.target as trg_id,
		st_startpoint(r.geom) as src, st_endpoint(r.geom) as trg,
		r.geom as geom
		from polyroads_all as r;

		--unique targets
		truncate target;
		insert into target
		with roads as (	
			select distinct on (c.gid) c.gid, c.geom, c.src_id, c.trg_id 
			from candidates as c, major_polys as p
			where not st_contains(p.geom, c.geom)
		)
		select distinct on (t.target) t.target from
		(select r.trg_id as target from roads as r
		union all
		select r.src_id as target from roads as r) as t;

		truncate source;
		insert into source		
		select distinct on (sr.src_id) sr.src_id from
		(select c.src_id as src_id, c.src
		from candidates as c, pgr_gb_major as p
		where st_dwithin(c.src, p.geom, 0.001) and not st_contains(p.geom, c.trg)
		union all
		select c.trg_id as src_id, c.trg
		from candidates as c, pgr_gb_major as p
		where st_dwithin(c.trg, p.geom, 0.001) and not st_contains(p.geom, c.src)) as sr;

		--ensure all sources are also targets		
		insert into target
		select s.source
		from source as s 
		where not exists (select t.target
		from target as t where t.target = s.source);
	 
 		--number of targets per poly
		insert into poly_count_coast (select x, count(*) from target);

 		--run pgr_kdijkstrapath routing
 		select count(*) from source into c1;
 		select count(*) from target into c2;
		if c1 != 0 and c2 != 0 then
 			perform get_path(s.source) from source as s;
 		end if;
	end loop;
end $$;