# Minor Roads: A method to estimate the importance of minor roads in terms of traffic flow

### This method is presented in: 
**_Morley, D.W., Gulliver, J., Methods to improve traffic flow and noise exposure estimation on minor roads,  Environmental Pollution (2016), http://dx.doi.org/10.1016/j.envpol.2016.06.042_**

Please see this paper for the background and rationale. The main aim of this study was to try and improve noise exposure estimates for people living in residential areas. Although a good coverage of traffic counts are available for major roads, minor roads are often assined a constant daily vehicle flow. This is a problem for exposure estimates as noise predictions are reliant on accurate traffic flow data. Here, we attempt to use network routing (similar to SatNav applications) to indentify which minor roads are most commonly used within the road network and assign an importance index accordingly. This can then be used to relate to traffic levels. 

All tools and data are freely available. Analysis is carried out using PostGIS with OpenStreetMap geographical data and UK Department of Transport traffic counts. It is assumed that you have already set up PostGIS and are able to import data and run queries.

The following steps give a demo to generate routing importance for the [Isle of Wight](https://goo.gl/maps/jSd8BwtXNgt) (a managable sized dataset which is well defined geographically). For very large datasets (e.g. the whole UK), the geographic data need to be split into more managable chunks as [Dijkstra](https://en.wikipedia.org/wiki/Dijkstra%27s_algorithm) is a greedy algorithm. More detail on what is actually going on is given in the scripts themselves

After downloading and importing the data, a method to assign actual counts to major roads is given before moving on to the method for assessing minor road importance.


### (1) SOFTWARE NEEDED
- [PostGIS](http://postgis.net/), a spatially enabled PostgreSQL database
- [pgRouting](http://pgrouting.org/), the routing extension for PostGIS
- [osm2po](http://osm2po.de/), an application to download and import OSM data 
- [QGIS](http://www.qgis.org/en/site/), a desktop GIS very useful for viewing PostGIS output 

### (2) DATA NEEDED
- [DfT traffic counts](http://www.dft.gov.uk/traffic-counts/download.php) (2013 provided here in data folder)
- [OSM](https://www.openstreetmap.org/) data in various formats (see [Geofabrik](http://download.geofabrik.de/) for URLs needed in step 3)

### (3) DOWNLOAD OSM DATA
- Edit the file 'downloadOSM.bat' using a text editor
- Change the URL to your study area (make sure you use the .osm.bz2 data)
- Here, we have pre-defined the Isle of Wight
- Right-click > Open, to run the batch file. Results are stored in the 'C:/osm2po-5.0.0 folder'
- In addition, download from geofabrik the corresponding .shp.zip file and keep just the 'roads' shapefile

### (4) IMPORT OSM DATA TO POSTGIS
- Edit the file 'importOSM.bat' using a text editor
- Set your PostGIS details
- Set the location of the results from (3)
- Ensure '-d' points to an existing database 
- Right-click > Open, to run the batch file.
- Use the PostGIS shapefile importer to add the corresponding 'roads' shapefile from (3)

### (5) ASSIGN TRAFFIC COUNTS TO MAJOR ROADS
- The DfT major road traffic counts are fairly complete for all UK major roads
- The script 'major_assignment.sql' assigns counts to roads
- See the comments in the script for more details

### (6) PREPARE MINOR ROADS DATA
- Work through the 'minor_assignment_dataprep.sql' script 
- Minor roads are handled in groups defined by distinct areas bounded by major roads (that is distinct networks of minor roads only accessible to each other without a major road being crossed. Think of the holes in a net pattern created by the major road network).
- In the image below, major roads are red. Two polygons are shown in blue, each containing a network of minor roads. Source points are taken as where minor roads join the major roads. Target points are all other road links within the polygon. Bridges and Tunnels over/under a major road are excluded as source points.

![iow1](/png/iow1.PNG)

- Note that coastal areas cannot be defined in this way (major road enclosed polygon). These are dealt with as on the basis of grouping as those only being able to access other minor roads without crossing a major road. Individual groups are shown coloured below.

![iow2](/png/iow2.PNG)

### (7) RUN THE ROUTING ANALYSIS
- Work through the 'minor_assignment_routing.sql' script 
- This runs the Dijkstra algorithm for the major road enclosed areas, then the coastal minor roads
- The results is the table 'totals' which contains a raw count of how many times each road (by id attribute) was transversed during the routing iterations.

### (8) STANDARDISING THE RAW COUNTS
- Work through the 'minor_assignment_index.sql' script 
- Raw counts need to be standardised as the count is dependent on the number of roads in an area and the associated number of source and target points. Standardisation is carried out here by dividing the total count per area, by the number of road links within that AOI.
- The final results. Red roads are the major roads to which actual traffic counts were assigned in (5). Minor roads are blue and are shaded according to the estimated index of importance (darker is more important).

![iow3](/png/iow3.PNG)
![iow4](/png/iow4.PNG)
![iow5](/png/iow5.PNG)

### (9) NEXT STEPS
- The estimated minor road importance index needs to be translated into a traffic count value for application in noise and air pollution models. This is an area that needs further work. In the paper, Morley and Gulliver (2016), a method is presented using a Poisson regression model using a small set of DfT counts on minor roads as a training set. The regression equation was as follows:

```
AADT ~ log(route importance) + (OSM Road Type) + log(AADT on nearest major road) + (Urban or Rural)
```

- There are clear limitations with this method that are discussed in the accompanying paper. The overall aim here was to provide an acceptable correction to the problem of noise models being generated using constant traffic flows on minor roads.







