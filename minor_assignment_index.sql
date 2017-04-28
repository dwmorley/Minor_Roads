
-- We have now generated a count of the number of times each minor road is transversed,
-- higher counts indicate more important roads for traffic. These are raw counts and
-- need to be standardised as the count is dependent on the number of roads in an AOI and
-- the associated number of source and target points. Standardisation is carried out here
-- by dividing the total count per AOI, by the number of road links within that AOI


-- (1) Give any un-traversed edges a score of 1 to avoid division errors
update totals set total = 1 where total = 0;


-- (2) Find the denominator to standardise counts by. This is the total number of minor roads.
-- As a minor road (by ID) may cover more than one AOI, the AOI that it belongs to is calculated
-- as that which contains the majority of that particular road.

-- Midpoint of all roads
drop table if exists road_centres;
create table road_centres as 
select r.gid, ST_LineInterpolatePoint(r.geom, 0.5) as geom
from pgr_gb as r;
create index road_centres_indx on road_centres using gist(geom);

-- Get only minor roads in that are not on the coast
drop table if exists not_coast_roads;
create table not_coast_roads as
select r.gid, r.geom from
(select r.gid from road_centres as r, major_polys as p
where st_intersects(p.geom, r.geom)) as c left join pgr_gb as r
on r.gid = c.gid
where r.minor = 1;
create index not_coast_roads_indx on not_coast_roads using gist(geom);

-- Get which roads are within each AOI
-- This can be multiple if a road crosses a boundary
-- In the next step the AOI with the majority of the road is taken as the containing AOI
drop table if exists road_poly_intersects;
create table road_poly_intersects as
select g.gid, g.geom, p.gid as poly_gid
from major_polys as p, not_coast_roads as g
where st_intersects(p.geom, g.geom);
create index road_poly_intersects_indx on road_poly_intersects using gist(geom); 

-- length of intersections
drop table if exists road_intersect_length;
create table road_intersect_length as
select i.gid, st_length(st_intersection(st_makevalid(p.geom), st_makevalid(i.geom))) as length, i.poly_gid
from road_poly_intersects as i left join major_polys as p
on p.gid = i.poly_gid
where p.gid = i.poly_gid; 

-- Get the AOI where the road is longest
drop table if exists intersect_majority;
create table intersect_majority as
select distinct on (i.gid) i.gid, i.poly_gid
from road_intersect_length as i
group by i.gid, i.length, i.poly_gid
order by i.gid, i.length desc;

-- Count up the total number of minor roads per poly 
drop table if exists major_poly_road_counts;
create table major_poly_road_counts as
select i.poly_gid, count(i.poly_gid) as count
from intersect_majority as i
group by i.poly_gid;

-- (3) Do the same for the coastal road groups
drop table if exists coast_roads;
create table coast_roads as
select r.gid, r.geom, r.fclass
from pgr_gb_minor as r where not exists (select 1
	from (select distinct on (r.gid) r.gid from pgr_gb_minor as r, major_poly_buf as p
		where st_contains(p.geom, r.geom)) as ip
		where ip.gid = r.gid);
drop index if exists major_poly_buf_indx;
create index major_poly_buf_indx on major_poly_buf using gist(geom); 

-- Count up the total number of minor roads per coastal group 
drop table if exists coast_road_counts;
create table coast_road_counts as
select i.id, count(i.id) as count
from coast_roads_net as i
group by i.id;


-- (4) Standardise counts
drop table if exists poly_norms;
create table poly_norms as 
select t.gid, t.total, t.poly_gid, n.count, 0 as coast
from 
(select i.gid, x.total, i.poly_gid from intersect_majority as i left join totals as x on i.gid = x.gid) as t
left join major_poly_road_counts as n
on n.poly_gid = t.poly_gid;

-- make sure not already in a poly (not exists)
drop table if exists coast_norms;
create table coast_norms as 
select c.gid, c.total, c.id as poly_gid, n.count, 1 as coast
from (select c.gid, c.id, t.total from coast_roads_net as c left join 
(select t.gid, t.total from totals as t where not exists (select p.gid from poly_norms as p where p.gid = t.gid)) as t 
on t.gid = c.gid) as c
left join coast_road_counts as n
on c.id = n.id; 

-- table of totals and counts, non-geographic
drop table if exists pgr_gb_norms;
create table pgr_gb_norms as 
with u as (
	select * from poly_norms
	union all
	select * from coast_norms
)
select * from u
union all
--where are the null roads these are dangles, set these to count = 1, total = 1
select r.gid, 1 as total, 0 as poly_gid, 1 as count, 1 as coast from pgr_gb as r
where not exists(select n.gid from u as n where n.gid = r.gid) and r.minor = 1;



-- (5) Make the final spatial layer containing minor road geography and road importance index
drop table if exists pgr_gb_routed;
create table pgr_gb_routed as
select j.*, r.geom, r.fclass, r.oneway from (select distinct on (n.gid) n.gid, n.total, n.count, (n.total / cast(n.count as numeric)) as norm from pgr_gb_norms as n
order by n.gid, n.total desc) as j left join pgr_gb as r
on r.gid = j.gid;
drop index if exists pgr_gb_routed_indx;
create index pgr_gb_routed_indx on pgr_gb_routed using gist(geom);


-- (6) The next step would be to relate this road importance to AADT
-- This is still and area in which more work is needed
-- For info on a possible way to do this please see the paper
-- https://www.researchgate.net/publication/304460508_Methods_to_improve_traffic_flow_and_noise_exposure_estimation_on_minor_roads