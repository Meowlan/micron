Micron = Micron or {}
Micron.Math = Micron.Math or {}

local Math = Micron.Math

local EPSILON = 1e-6

function Math.SafeNormalize(vec, fallback)
    if not vec then
        return (fallback or Vector(0, 0, 1)):GetNormalized()
    end

    local length = vec:Length()
    if length <= EPSILON then
        local safeFallback = fallback or Vector(0, 0, 1)
        if safeFallback:Length() <= EPSILON then
            return Vector(0, 0, 1)
        end

        return safeFallback:GetNormalized()
    end

    return vec / length
end

function Math.ProjectOntoPlane(vec, normal)
    return vec - normal * vec:Dot(normal)
end

function Math.WorldDirToLocal(ent, dir)
    local originLocal = ent:WorldToLocal(ent:GetPos())
    local tipLocal = ent:WorldToLocal(ent:GetPos() + dir)
    return Math.SafeNormalize(tipLocal - originLocal, Vector(0, 0, 1))
end

function Math.LocalDirToWorld(ent, dir)
    local originWorld = ent:LocalToWorld(Vector(0, 0, 0))
    local tipWorld = ent:LocalToWorld(dir)
    return Math.SafeNormalize(tipWorld - originWorld, Vector(0, 0, 1))
end

function Math.BuildBasis(normal, hint)
    local n = Math.SafeNormalize(normal, Vector(0, 0, 1))
    local projectedHint = Math.ProjectOntoPlane(hint or Vector(1, 0, 0), n)
    local u

    if projectedHint:LengthSqr() <= (EPSILON * EPSILON) then
        local fallback = math.abs(n.z) < 0.999 and Vector(0, 0, 1) or Vector(1, 0, 0)
        u = Math.SafeNormalize(Math.ProjectOntoPlane(fallback, n), Vector(1, 0, 0))
    else
        u = projectedHint:GetNormalized()
    end

    local v = Math.SafeNormalize(n:Cross(u), Vector(0, 1, 0))
    u = Math.SafeNormalize(v:Cross(n), Vector(1, 0, 0))

    return {
        u = u,
        v = v,
        n = n
    }
end

function Math.RotateVectorAroundAxis(vec, axis, degrees)
    local axisSafe = Math.SafeNormalize(axis, Vector(0, 0, 1))
    local rad = math.rad(degrees or 0)
    local cosA = math.cos(rad)
    local sinA = math.sin(rad)

    return vec * cosA + axisSafe:Cross(vec) * sinA + axisSafe * axisSafe:Dot(vec) * (1 - cosA)
end

function Math.RotateBasisAroundAxis(basis, axisName, degrees)
    if not basis or not basis[axisName] then
        return basis
    end

    if not degrees or math.abs(degrees) <= EPSILON then
        return {
            u = basis.u,
            v = basis.v,
            n = basis.n
        }
    end

    local axis = Math.SafeNormalize(basis[axisName], Vector(0, 0, 1))
    local out = {
        u = basis.u,
        v = basis.v,
        n = basis.n
    }

    if axisName ~= "u" then
        out.u = Math.SafeNormalize(Math.RotateVectorAroundAxis(out.u, axis, degrees), out.u)
    end

    if axisName ~= "v" then
        out.v = Math.SafeNormalize(Math.RotateVectorAroundAxis(out.v, axis, degrees), out.v)
    end

    if axisName ~= "n" then
        out.n = Math.SafeNormalize(Math.RotateVectorAroundAxis(out.n, axis, degrees), out.n)
    end

    out = Math.BuildBasis(out.n, out.u)
    return out
end

function Math.MapLocalVectorToWorld(localVec, sourceBasis, destinationBasis)
    local weightU = sourceBasis.u:Dot(localVec)
    local weightV = sourceBasis.v:Dot(localVec)
    local weightN = sourceBasis.n:Dot(localVec)

    return destinationBasis.u * weightU + destinationBasis.v * weightV + destinationBasis.n * weightN
end

function Math.BasisToWorldAngle(worldForward, worldLeft, worldUp)
    local forward = Math.SafeNormalize(worldForward, Vector(1, 0, 0))
    local leftHint = Math.SafeNormalize(worldLeft, Vector(0, 1, 0))
    local upHint = Math.SafeNormalize(worldUp, Vector(0, 0, 1))

    local rightProjected = -leftHint - forward * forward:Dot(-leftHint)
    local right
    if rightProjected:LengthSqr() <= (EPSILON * EPSILON) then
        right = Math.SafeNormalize(forward:Cross(upHint), Vector(0, -1, 0))
    else
        right = rightProjected:GetNormalized()
    end

    local up = Math.SafeNormalize(right:Cross(forward), Vector(0, 0, 1))

    local matrix = Matrix()
    matrix:SetForward(forward)
    matrix:SetRight(right)
    matrix:SetUp(up)

    return matrix:GetAngles()
end

function Math.WrapRightAngle(degrees)
    local normalized = math.floor((degrees or 0) / 90 + 0.5) * 90
    normalized = normalized % 360

    if normalized < 0 then
        normalized = normalized + 360
    end

    return normalized
end
