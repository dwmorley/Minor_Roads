REM ################################################
REM download OSM data from geofabrik using osm2po
REM ################################################
REM 
REM see http://osm2po.de/
REM select your .bz2 from http://download.geofabrik.de

java -Xmx1408m -jar osm2po-core-5.0.0-signed.jar prefix=hh tileSize=x,c http://download.geofabrik.de/europe/great-britain/england/isle-of-wight-latest.osm.bz2
