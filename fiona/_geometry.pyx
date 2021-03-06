# Coordinate and geometry transformations.

import logging


class NullHandler(logging.Handler):
    def emit(self, record):
        pass

log = logging.getLogger("Fiona")
log.addHandler(NullHandler())

# Mapping of OGR integer geometry types to GeoJSON type names.
GEOMETRY_TYPES = {
    0: 'Unknown',
    1: 'Point',
    2: 'LineString',
    3: 'Polygon',
    4: 'MultiPoint',
    5: 'MultiLineString',
    6: 'MultiPolygon',
    7: 'GeometryCollection',
    100: 'None',
    101: 'LinearRing',
    0x80000001: '3D Point',
    0x80000002: '3D LineString',
    0x80000003: '3D Polygon',
    0x80000004: '3D MultiPoint',
    0x80000005: '3D MultiLineString',
    0x80000006: '3D MultiPolygon',
    0x80000007: '3D GeometryCollection' }

# mapping of GeoJSON type names to OGR integer geometry types
GEOJSON2OGR_GEOMETRY_TYPES = dict((v, k) for k, v in GEOMETRY_TYPES.iteritems())


# Geometry related functions and classes follow.
cdef void * _createOgrGeomFromWKB(object wkb) except NULL:
    """Make an OGR geometry from a WKB string"""
    wkbtype = bytearray(wkb)[1]
    cdef unsigned char *buffer = wkb
    cdef void *cogr_geometry = OGR_G_CreateGeometry(wkbtype)
    if cogr_geometry is not NULL:
        OGR_G_ImportFromWkb(cogr_geometry, buffer, len(wkb))
    return cogr_geometry


cdef _deleteOgrGeom(void *cogr_geometry):
    """Delete an OGR geometry"""
    if cogr_geometry is not NULL:
        OGR_G_DestroyGeometry(cogr_geometry)
    cogr_geometry = NULL


cdef class GeomBuilder:
    """Builds Fiona (GeoJSON) geometries from an OGR geometry handle.
    """
    cdef _buildCoords(self, void *geom):
        # Build a coordinate sequence
        cdef int i
        if geom == NULL:
            raise ValueError("Null geom")
        npoints = OGR_G_GetPointCount(geom)
        coords = []
        for i in range(npoints):
            values = [OGR_G_GetX(geom, i), OGR_G_GetY(geom, i)]
            if self.ndims > 2:
                values.append(OGR_G_GetZ(geom, i))
            coords.append(tuple(values))
        return coords
    
    cpdef _buildPoint(self):
        return {'type': 'Point', 'coordinates': self._buildCoords(self.geom)[0]}
    
    cpdef _buildLineString(self):
        return {'type': 'LineString', 'coordinates': self._buildCoords(self.geom)}
    
    cpdef _buildLinearRing(self):
        return {'type': 'LinearRing', 'coordinates': self._buildCoords(self.geom)}
    
    cdef _buildParts(self, void *geom):
        cdef int j
        cdef void *part
        if geom == NULL:
            raise ValueError("Null geom")
        parts = []
        for j in range(OGR_G_GetGeometryCount(geom)):
            part = OGR_G_GetGeometryRef(geom, j)
            parts.append(GeomBuilder().build(part))
        return parts
    
    cpdef _buildPolygon(self):
        coordinates = [p['coordinates'] for p in self._buildParts(self.geom)]
        return {'type': 'Polygon', 'coordinates': coordinates}
    
    cpdef _buildMultiPoint(self):
        coordinates = [p['coordinates'] for p in self._buildParts(self.geom)]
        return {'type': 'MultiPoint', 'coordinates': coordinates}
    
    cpdef _buildMultiLineString(self):
        coordinates = [p['coordinates'] for p in self._buildParts(self.geom)]
        return {'type': 'MultiLineString', 'coordinates': coordinates}
    
    cpdef _buildMultiPolygon(self):
        coordinates = [p['coordinates'] for p in self._buildParts(self.geom)]
        return {'type': 'MultiPolygon', 'coordinates': coordinates}

    cpdef _buildGeometryCollection(self):
        parts = self._buildParts(self.geom)
        return {'type': 'GeometryCollection', 'geometries': parts}
    
    cdef build(self, void *geom):
        # The only method anyone needs to call
        if geom == NULL:
            raise ValueError("Null geom")
        
        cdef unsigned int etype = OGR_G_GetGeometryType(geom)
        self.code = etype
        self.geomtypename = GEOMETRY_TYPES[self.code & (~0x80000000)]
        self.ndims = OGR_G_GetCoordinateDimension(geom)
        self.geom = geom
        return getattr(self, '_build' + self.geomtypename)()
    
    cpdef build_wkb(self, object wkb):
        # The only other method anyone needs to call
        cdef object data = wkb
        cdef void *cogr_geometry = _createOgrGeomFromWKB(data)
        result = self.build(cogr_geometry)
        _deleteOgrGeom(cogr_geometry)
        return result


cdef class OGRGeomBuilder:
    """Builds OGR geometries from Fiona geometries.
    """
    cdef void * _createOgrGeometry(self, int geom_type) except NULL:
        cdef void *cogr_geometry = OGR_G_CreateGeometry(geom_type)
        if cogr_geometry == NULL:
            raise Exception("Could not create OGR Geometry of type: %i" % geom_type)
        return cogr_geometry

    cdef _addPointToGeometry(self, void *cogr_geometry, object coordinate):
        if len(coordinate) == 2:
            x, y = coordinate
            OGR_G_AddPoint_2D(cogr_geometry, x, y)
        else:
            x, y, z = coordinate[:3]
            OGR_G_AddPoint(cogr_geometry, x, y, z)

    cdef void * _buildPoint(self, object coordinates) except NULL:
        cdef void *cogr_geometry = self._createOgrGeometry(GEOJSON2OGR_GEOMETRY_TYPES['Point'])
        self._addPointToGeometry(cogr_geometry, coordinates)
        return cogr_geometry
    
    cdef void * _buildLineString(self, object coordinates) except NULL:
        cdef void *cogr_geometry = self._createOgrGeometry(GEOJSON2OGR_GEOMETRY_TYPES['LineString'])
        for coordinate in coordinates:
            log.debug("Adding point %s", coordinate)
            self._addPointToGeometry(cogr_geometry, coordinate)
        return cogr_geometry
    
    cdef void * _buildLinearRing(self, object coordinates) except NULL:
        cdef void *cogr_geometry = self._createOgrGeometry(GEOJSON2OGR_GEOMETRY_TYPES['LinearRing'])
        for coordinate in coordinates:
            log.debug("Adding point %s", coordinate)
            self._addPointToGeometry(cogr_geometry, coordinate)
        log.debug("Closing ring")
        OGR_G_CloseRings(cogr_geometry)
        return cogr_geometry
    
    cdef void * _buildPolygon(self, object coordinates) except NULL:
        cdef void *cogr_ring
        cdef void *cogr_geometry = self._createOgrGeometry(GEOJSON2OGR_GEOMETRY_TYPES['Polygon'])
        for ring in coordinates:
            log.debug("Adding ring %s", ring)
            cogr_ring = self._buildLinearRing(ring)
            log.debug("Built ring")
            OGR_G_AddGeometryDirectly(cogr_geometry, cogr_ring)
            log.debug("Added ring %s", ring)
        return cogr_geometry

    cdef void * _buildMultiPoint(self, object coordinates) except NULL:
        cdef void *cogr_part
        cdef void *cogr_geometry = self._createOgrGeometry(GEOJSON2OGR_GEOMETRY_TYPES['MultiPoint'])
        for coordinate in coordinates:
            log.debug("Adding point %s", coordinate)
            cogr_part = self._buildPoint(coordinate)
            OGR_G_AddGeometryDirectly(cogr_geometry, cogr_part)
            log.debug("Added point %s", coordinate)
        return cogr_geometry

    cdef void * _buildMultiLineString(self, object coordinates) except NULL:
        cdef void *cogr_part
        cdef void *cogr_geometry = self._createOgrGeometry(GEOJSON2OGR_GEOMETRY_TYPES['MultiLineString'])
        for line in coordinates:
            log.debug("Adding line %s", line)
            cogr_part = self._buildLineString(line)
            log.debug("Built line")
            OGR_G_AddGeometryDirectly(cogr_geometry, cogr_part)
            log.debug("Added line %s", line)
        return cogr_geometry

    cdef void * _buildMultiPolygon(self, object coordinates) except NULL:
        cdef void *cogr_part
        cdef void *cogr_geometry = self._createOgrGeometry(GEOJSON2OGR_GEOMETRY_TYPES['MultiPolygon'])
        for part in coordinates:
            log.debug("Adding polygon %s", part)
            cogr_part = self._buildPolygon(part)
            log.debug("Built polygon")
            OGR_G_AddGeometryDirectly(cogr_geometry, cogr_part)
            log.debug("Added polygon %s", part)
        return cogr_geometry

    cdef void * _buildGeometryCollection(self, object coordinates) except NULL:
        cdef void *cogr_part
        cdef void *cogr_geometry = self._createOgrGeometry(GEOJSON2OGR_GEOMETRY_TYPES['GeometryCollection'])
        for part in coordinates:
            log.debug("Adding part %s", part)
            cogr_part = OGRGeomBuilder().build(part)
            log.debug("Built part")
            OGR_G_AddGeometryDirectly(cogr_geometry, cogr_part)
            log.debug("Added part %s", part)
        return cogr_geometry

    cdef void * build(self, object geometry) except NULL:
        cdef object typename = geometry['type']
        cdef object coordinates = geometry.get('coordinates')
        if typename == 'Point':
            return self._buildPoint(coordinates)
        elif typename == 'LineString':
            return self._buildLineString(coordinates)
        elif typename == 'LinearRing':
            return self._buildLinearRing(coordinates)
        elif typename == 'Polygon':
            return self._buildPolygon(coordinates)
        elif typename == 'MultiPoint':
            return self._buildMultiPoint(coordinates)
        elif typename == 'MultiLineString':
            return self._buildMultiLineString(coordinates)
        elif typename == 'MultiPolygon':
            return self._buildMultiPolygon(coordinates)
        elif typename == 'GeometryCollection':
            coordinates = geometry.get('geometries')
            return self._buildGeometryCollection(coordinates)
        else:
            raise ValueError("Unsupported geometry type %s" % typename)


cdef geometry(void *geom):
    """Factory for Fiona geometries"""
    return GeomBuilder().build(geom)


def geometryRT(geometry):
    # For testing purposes only, leaks the JSON data
    cdef void *cogr_geometry = OGRGeomBuilder().build(geometry)
    result = GeomBuilder().build(cogr_geometry)
    _deleteOgrGeom(cogr_geometry)
    return result
