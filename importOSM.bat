REM ################################################
REM import OSM data downloaded by osm2po into postgres	
REM ################################################
REM
REM Ensure postgres details are correct for your system

set PSQL="C:\Program Files\PostgreSQL\9.4\bin\psql"
set PGPORT=5432
set PGHOST=localhost
set PGPASSWORD=astr2n2m

REM P:\osm2po-5.0.0\hh is where the output from importOSM.bat was stored
P:
cd P:\osm2po-5.0.0\hh

REM Ensure -U is your postgres username, -d is an existing PostGIS database
REM hh_2po_4pgr.sql will be the output SQL file from the geofabrik download

%PSQL% -U postgres -d minor -q -f "hh_2po_4pgr.sql"
pause