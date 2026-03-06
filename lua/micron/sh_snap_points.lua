Micron = Micron or {}
Micron.SnapPoints = Micron.SnapPoints or {}

local SnapPoints = Micron.SnapPoints
local Math = Micron.Math

local EPSILON = 1e-5
local EPSILON_SQR = EPSILON * EPSILON
local DEFAULT_GRID_SUBDIVISIONS = 6
local MIN_GRID_SUBDIVISIONS = 1
local MAX_GRID_SUBDIVISIONS = 24

local GRID_FACE_INSET_UNITS = 0.355

local BOX_EDGES = {
    {1, 2}, {1, 3}, {1, 5}, {2, 4}, {2, 6}, {3, 4},
    {3, 7}, {4, 8}, {5, 6}, {5, 7}, {6, 8}, {7, 8}
}

local function clampGridSubdivisions(value)
    local asNumber = tonumber(value) or DEFAULT_GRID_SUBDIVISIONS
    asNumber = math.floor(asNumber)

    if asNumber < MIN_GRID_SUBDIVISIONS then
        return MIN_GRID_SUBDIVISIONS
    end

    if asNumber > MAX_GRID_SUBDIVISIONS then
        return MAX_GRID_SUBDIVISIONS
    end

    return asNumber
end

local function isSnappableEntity(ent)
    if not IsValid(ent) then return false end
    if ent:IsPlayer() or ent:IsNPC() or ent:IsWeapon() then return false end

    if CLIENT then
        return true
    end

    local phys = ent:GetPhysicsObject()
    return IsValid(phys)
end

local function buildObbCorners(mins, maxs)
    local corners = {}

    for i = 0, 7 do
        corners[#corners + 1] = Vector(
            bit.band(i, 1) ~= 0 and maxs.x or mins.x,
            bit.band(i, 2) ~= 0 and maxs.y or mins.y,
            bit.band(i, 4) ~= 0 and maxs.z or mins.z
        )
    end

    return corners
end

local function signedPlaneDistance(normal, pointOnPlane, point)
    return normal:Dot(point - pointOnPlane)
end

local function intersectSegmentPlane(p0, p1, normal, pointOnPlane)
    local dir = p1 - p0
    local denom = normal:Dot(dir)

    if math.abs(denom) <= EPSILON then
        local d0 = signedPlaneDistance(normal, pointOnPlane, p0)
        local d1 = signedPlaneDistance(normal, pointOnPlane, p1)
        if math.abs(d0) <= EPSILON and math.abs(d1) <= EPSILON then
            return true, p0
        end

        return false, nil
    end

    local t = -signedPlaneDistance(normal, pointOnPlane, p0) / denom
    if t < -EPSILON or t > (1 + EPSILON) then
        return false, nil
    end

    return true, p0 + dir * t
end

local function insertUniquePoint(points, candidate)
    for _, point in ipairs(points) do
        if point:DistToSqr(candidate) <= EPSILON_SQR then
            return
        end
    end

    points[#points + 1] = candidate
end

local function insertUniqueScalar(values, candidate)
    for _, value in ipairs(values) do
        if math.abs(value - candidate) <= EPSILON then
            return
        end
    end

    values[#values + 1] = candidate
end

local function pointOnSegment2D(a, b, p)
    local abx = b.x - a.x
    local aby = b.y - a.y
    local ab2 = abx * abx + aby * aby

    if ab2 <= EPSILON_SQR then
        local dx = p.x - a.x
        local dy = p.y - a.y
        return (dx * dx + dy * dy) <= EPSILON_SQR
    end

    local apx = p.x - a.x
    local apy = p.y - a.y
    local t = (apx * abx + apy * aby) / ab2
    if t < -EPSILON or t > (1 + EPSILON) then
        return false
    end

    local projX = a.x + abx * t
    local projY = a.y + aby * t
    local ddx = projX - p.x
    local ddy = projY - p.y

    return (ddx * ddx + ddy * ddy) <= EPSILON_SQR
end

local function pointInPolygon2D(poly, p)
    if #poly < 3 then
        return false
    end

    local j = #poly
    for i = 1, #poly do
        if pointOnSegment2D(poly[j], poly[i], p) then
            return true
        end
        j = i
    end

    local inside = false
    j = #poly
    for i = 1, #poly do
        local pi = poly[i]
        local pj = poly[j]
        local yi = pi.y > p.y
        local yj = pj.y > p.y

        if yi ~= yj then
            local xIntersect = pi.x + (p.y - pi.y) * (pj.x - pi.x) / (pj.y - pi.y)
            if p.x < xIntersect then
                inside = not inside
            end
        end

        j = i
    end

    return inside
end

local function computeBasisForFace(normal, orderedVerts)
    local hint = nil

    if #orderedVerts >= 2 then
        local edge = orderedVerts[2] - orderedVerts[1]
        if edge:LengthSqr() > EPSILON_SQR then
            hint = edge:GetNormalized()
        end
    end

    return Math.BuildBasis(normal, hint)
end

local function project2D(point, origin, basis)
    local rel = point - origin
    return {
        x = rel:Dot(basis.u),
        y = rel:Dot(basis.v)
    }
end

local function to3D(origin, basis, x, y)
    return origin + basis.u * x + basis.v * y
end

local function computeCentroidAndOrder(points, normal)
    local averageCenter = Vector(0, 0, 0)
    for _, point in ipairs(points) do
        averageCenter = averageCenter + point
    end
    averageCenter = averageCenter / #points

    local sortingBasis = Math.BuildBasis(normal, Vector(1, 0, 0))

    local projected = {}
    for _, point in ipairs(points) do
        local p2 = project2D(point, averageCenter, sortingBasis)
        projected[#projected + 1] = {
            point = point,
            x = p2.x,
            y = p2.y,
            angle = math.atan2(p2.y, p2.x)
        }
    end

    table.sort(projected, function(a, b)
        return a.angle < b.angle
    end)

    local ordered = {}
    local poly2d = {}
    for _, item in ipairs(projected) do
        ordered[#ordered + 1] = item.point
        poly2d[#poly2d + 1] = {
            x = item.x,
            y = item.y
        }
    end

    local area2 = 0
    local cx = 0
    local cy = 0
    local count = #poly2d

    for i = 1, count do
        local j = (i % count) + 1
        local cross = poly2d[i].x * poly2d[j].y - poly2d[j].x * poly2d[i].y
        area2 = area2 + cross
        cx = cx + (poly2d[i].x + poly2d[j].x) * cross
        cy = cy + (poly2d[i].y + poly2d[j].y) * cross
    end

    local center2d
    if math.abs(area2) > EPSILON then
        center2d = {
            x = cx / (3 * area2),
            y = cy / (3 * area2)
        }
    else
        center2d = { x = 0, y = 0 }
        for _, p in ipairs(poly2d) do
            center2d.x = center2d.x + p.x
            center2d.y = center2d.y + p.y
        end

        center2d.x = center2d.x / count
        center2d.y = center2d.y / count
    end

    local center3d = averageCenter + sortingBasis.u * center2d.x + sortingBasis.v * center2d.y
    return center3d, ordered
end

local function insetFaceVertices(vertices, center, insetUnits)
    if insetUnits <= EPSILON then
        return vertices
    end

    local maxRadius = 0
    for _, vertex in ipairs(vertices) do
        local radius = (vertex - center):Length()
        if radius > maxRadius then
            maxRadius = radius
        end
    end

    if maxRadius <= EPSILON then
        return vertices
    end

    local appliedInset = math.min(insetUnits, maxRadius * 0.45)
    local scale = math.max(0, (maxRadius - appliedInset) / maxRadius)
    if math.abs(scale - 1) <= EPSILON then
        return vertices
    end

    local insetVertices = {}
    for i, vertex in ipairs(vertices) do
        insetVertices[i] = center + (vertex - center) * scale
    end

    return insetVertices
end

local function computePoly2D(vertices, center, basis)
    local poly = {}
    local minX, maxX = nil, nil
    local minY, maxY = nil, nil

    for _, vertex in ipairs(vertices) do
        local p = project2D(vertex, center, basis)
        poly[#poly + 1] = p

        minX = minX and math.min(minX, p.x) or p.x
        maxX = maxX and math.max(maxX, p.x) or p.x
        minY = minY and math.min(minY, p.y) or p.y
        maxY = maxY and math.max(maxY, p.y) or p.y
    end

    return poly, {
        minX = minX,
        maxX = maxX,
        minY = minY,
        maxY = maxY
    }
end

local function collectVerticalIntersections(poly, x)
    local intersections = {}

    for i = 1, #poly do
        local j = (i % #poly) + 1
        local a = poly[i]
        local b = poly[j]

        if math.abs(a.x - b.x) <= EPSILON then
            if math.abs(x - a.x) <= EPSILON then
                insertUniqueScalar(intersections, a.y)
                insertUniqueScalar(intersections, b.y)
            end
        else
            local minX = math.min(a.x, b.x)
            local maxX = math.max(a.x, b.x)
            if x >= (minX - EPSILON) and x <= (maxX + EPSILON) then
                local t = (x - a.x) / (b.x - a.x)
                local y = a.y + (b.y - a.y) * t
                insertUniqueScalar(intersections, y)
            end
        end
    end

    table.sort(intersections)
    return intersections
end

local function collectHorizontalIntersections(poly, y)
    local intersections = {}

    for i = 1, #poly do
        local j = (i % #poly) + 1
        local a = poly[i]
        local b = poly[j]

        if math.abs(a.y - b.y) <= EPSILON then
            if math.abs(y - a.y) <= EPSILON then
                insertUniqueScalar(intersections, a.x)
                insertUniqueScalar(intersections, b.x)
            end
        else
            local minY = math.min(a.y, b.y)
            local maxY = math.max(a.y, b.y)
            if y >= (minY - EPSILON) and y <= (maxY + EPSILON) then
                local t = (y - a.y) / (b.y - a.y)
                local x = a.x + (b.x - a.x) * t
                insertUniqueScalar(intersections, x)
            end
        end
    end

    table.sort(intersections)
    return intersections
end

local function buildFacePolygon(mins, maxs, hitPosLocal, hitNormalLocal)
    local corners = buildObbCorners(mins, maxs)
    local intersections = {}

    for _, edge in ipairs(BOX_EDGES) do
        local p0 = corners[edge[1]]
        local p1 = corners[edge[2]]
        local hit, point = intersectSegmentPlane(p0, p1, hitNormalLocal, hitPosLocal)

        if hit and point then
            insertUniquePoint(intersections, point)
        end
    end

    if #intersections < 3 then
        return nil
    end

    local center, orderedVerts = computeCentroidAndOrder(intersections, hitNormalLocal)
    if #orderedVerts < 3 then
        return nil
    end

    orderedVerts = insetFaceVertices(orderedVerts, center, GRID_FACE_INSET_UNITS)

    local basis = computeBasisForFace(hitNormalLocal, orderedVerts)
    local poly2D, bounds2D = computePoly2D(orderedVerts, center, basis)

    return {
        center = center,
        vertices = orderedVerts,
        basis = basis,
        poly2D = poly2D,
        bounds2D = bounds2D
    }
end

local function buildGridLines(face, subdivisions)
    local lines = {}

    for i = 1, #face.vertices do
        local j = (i % #face.vertices) + 1
        lines[#lines + 1] = {
            a = face.vertices[i],
            b = face.vertices[j],
            kind = "outline"
        }
    end

    local bounds = face.bounds2D
    local spanX = bounds.maxX - bounds.minX
    local spanY = bounds.maxY - bounds.minY
    if spanX <= EPSILON or spanY <= EPSILON then
        return lines
    end

    for step = 0, subdivisions do
        local t = step / subdivisions
        local x = bounds.minX + spanX * t
        local ys = collectVerticalIntersections(face.poly2D, x)

        local idx = 1
        while idx + 1 <= #ys do
            local yA = ys[idx]
            local yB = ys[idx + 1]
            if math.abs(yA - yB) > EPSILON then
                lines[#lines + 1] = {
                    a = to3D(face.center, face.basis, x, yA),
                    b = to3D(face.center, face.basis, x, yB),
                    kind = "grid"
                }
            end
            idx = idx + 2
        end
    end

    for step = 0, subdivisions do
        local t = step / subdivisions
        local y = bounds.minY + spanY * t
        local xs = collectHorizontalIntersections(face.poly2D, y)

        local idx = 1
        while idx + 1 <= #xs do
            local xA = xs[idx]
            local xB = xs[idx + 1]
            if math.abs(xA - xB) > EPSILON then
                lines[#lines + 1] = {
                    a = to3D(face.center, face.basis, xA, y),
                    b = to3D(face.center, face.basis, xB, y),
                    kind = "grid"
                }
            end
            idx = idx + 2
        end
    end

    return lines
end

local function addSnapPoint(points, position, normal, kind)
    for _, snap in ipairs(points) do
        if snap.position:DistToSqr(position) <= EPSILON_SQR then
            return
        end
    end

    points[#points + 1] = {
        position = position,
        normal = normal,
        kind = kind
    }
end

local function buildSnapPoints(face, subdivisions)
    local points = {}

    addSnapPoint(points, face.center, face.basis.n, "center")

    for i = 1, #face.vertices do
        addSnapPoint(points, face.vertices[i], face.basis.n, "vertex")
    end

    for i = 1, #face.vertices do
        local j = (i % #face.vertices) + 1
        addSnapPoint(points, (face.vertices[i] + face.vertices[j]) * 0.5, face.basis.n, "edge")
    end

    local bounds = face.bounds2D
    local spanX = bounds.maxX - bounds.minX
    local spanY = bounds.maxY - bounds.minY

    if spanX > EPSILON and spanY > EPSILON then
        for i = 0, subdivisions do
            local x = bounds.minX + spanX * (i / subdivisions)
            for j = 0, subdivisions do
                local y = bounds.minY + spanY * (j / subdivisions)
                local p2 = { x = x, y = y }
                if pointInPolygon2D(face.poly2D, p2) then
                    local p3 = to3D(face.center, face.basis, x, y)
                    addSnapPoint(points, p3, face.basis.n, "grid")
                end
            end
        end
    end

    return points
end

local function nearestSnapPoint(points, localHit)
    local bestIndex = nil
    local bestDist = math.huge

    for index, point in ipairs(points) do
        local dist = point.position:DistToSqr(localHit)
        if dist < bestDist then
            bestDist = dist
            bestIndex = index
        end
    end

    return bestIndex
end

function SnapPoints.ComputeLocal(obbMins, obbMaxs, hitPosLocal, hitNormalLocal, gridSubdivisions)
    local normal = Math.SafeNormalize(hitNormalLocal, Vector(0, 0, 1))
    local subdivisions = clampGridSubdivisions(gridSubdivisions)
    local face = buildFacePolygon(obbMins, obbMaxs, hitPosLocal, normal)
    if not face then
        return nil, "Could not derive a face polygon from hit data."
    end

    local points = buildSnapPoints(face, subdivisions)
    local lines = buildGridLines(face, subdivisions)
    local selectedIndex = nearestSnapPoint(points, hitPosLocal)
    if not selectedIndex then
        return nil, "No snap points were generated."
    end

    return {
        basis = face.basis,
        points = points,
        lines = lines,
        subdivisions = subdivisions,
        selectedIndex = selectedIndex,
        selectedPoint = points[selectedIndex]
    }
end

function SnapPoints.ComputeForEntity(ent, worldHitPos, worldHitNormal, gridSubdivisions)
    if not isSnappableEntity(ent) then
        return nil, "Target entity is not snappable."
    end

    local localHitPos = ent:WorldToLocal(worldHitPos)
    local localHitNormal = Math.WorldDirToLocal(ent, worldHitNormal)

    local snapData, err = SnapPoints.ComputeLocal(ent:OBBMins(), ent:OBBMaxs(), localHitPos, localHitNormal, gridSubdivisions)
    if not snapData then
        return nil, err
    end

    snapData.entity = ent
    snapData.localHitPos = localHitPos
    snapData.localHitNormal = localHitNormal

    return snapData
end

function SnapPoints.IsSnappableEntity(ent)
    return isSnappableEntity(ent)
end
