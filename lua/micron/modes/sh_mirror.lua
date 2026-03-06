Micron = Micron or {}
local Math = Micron.Math
local Registry = Micron.ModeRegistry
local Utils = Micron.ModeUtils
local SnapPoints = Micron.SnapPoints

local MODE = {}

MODE.DisplayName = "Mirror"
MODE.Description = "Define a plane, then mirror entities around it."
MODE.PreserveSourceAfterApply = true
MODE.DisableSnapVisualization = true
MODE.InvertDuplicateInput = true
MODE.ClientConVarDefaults = {
    freeze_prop = "1",
    weld_prop = "0",
    nocollide_pair = "0"
}

local function buildPlaneConnector(trace)
    if not trace or not trace.Hit then
        return nil, "No surface was hit."
    end

    local planeNormal = Math.SafeNormalize(trace.HitNormal, Vector(0, 0, 1))
    local planeHint = Utils.ChooseStableLocalHint(planeNormal)
    local planeBasis = Math.BuildBasis(planeNormal, planeHint)

    return {
        entity = nil,
        hitPosWorld = trace.HitPos,
        worldBasis = planeBasis,
        localPos = vector_origin,
        localBasis = planeBasis,
        isWorld = trace.HitWorld and true or false,
        isPlane = true
    }
end

local function buildMirrorTargetConnector(trace)
    if not trace or not trace.Hit then
        return nil, "No target was hit."
    end

    if trace.HitWorld then
        return nil, "Hit an entity to mirror."
    end

    local ent = trace.Entity
    if not SnapPoints or not SnapPoints.IsSnappableEntity or not SnapPoints.IsSnappableEntity(ent) then
        return nil, "Target entity cannot be mirrored."
    end

    return {
        entity = ent,
        hitPosWorld = trace.HitPos,
        worldBasis = nil,
        localPos = vector_origin,
        localBasis = nil,
        isWorld = false,
        isMirrorTarget = true
    }
end

local function mirrorPointAroundPlane(point, planePoint, planeNormal)
    local offset = point - planePoint
    return point - planeNormal * (2 * offset:Dot(planeNormal))
end

local function mirrorDirectionAroundPlane(direction, planeNormal)
    return Math.SafeNormalize(direction - planeNormal * (2 * direction:Dot(planeNormal)), Vector(1, 0, 0))
end

local function mirrorAnglesAroundPlane(angles, planeNormal)
    local mirroredForward = mirrorDirectionAroundPlane(angles:Forward(), planeNormal)
    local mirroredUp = mirrorDirectionAroundPlane(angles:Up(), planeNormal)

    local mirroredRight = Math.SafeNormalize(mirroredForward:Cross(mirroredUp), Vector(0, -1, 0))
    local orthonormalUp = Math.SafeNormalize(mirroredRight:Cross(mirroredForward), Vector(0, 0, 1))
    local mirroredLeft = -mirroredRight

    return Math.BasisToWorldAngle(mirroredForward, mirroredLeft, orthonormalUp)
end

function MODE.GetSettings(tool)
    local base = Utils.GetCommonSettings(tool)
    return {
        freezeProp = base.freezeProp,
        weldProp = false,
        nocollidePair = false
    }
end

function MODE.BuildConnector(ply, trace, _)
    local hasPlane = IsValid(ply) and ply:GetNW2Bool("Micron.HasSource", false)
    if hasPlane then
        return buildMirrorTargetConnector(trace)
    end

    return buildPlaneConnector(trace)
end

function MODE.Solve(sourceConnector, targetConnector)
    if not sourceConnector or not sourceConnector.hitPosWorld or not sourceConnector.worldBasis then
        return nil, "Missing mirror plane."
    end

    local targetEnt = targetConnector and targetConnector.entity or nil
    if not IsValid(targetEnt) then
        return nil, "Missing target entity."
    end

    local planePoint = sourceConnector.hitPosWorld
    local planeNormal = Math.SafeNormalize(sourceConnector.worldBasis.n, Vector(0, 0, 1))

    local finalPos = mirrorPointAroundPlane(targetEnt:GetPos(), planePoint, planeNormal)
    local finalAng = mirrorAnglesAroundPlane(targetEnt:GetAngles(), planeNormal)

    return {
        entity = targetEnt,
        position = finalPos,
        angles = finalAng
    }
end

if CLIENT then
    MODE.PanelClass = "MicronModeMirrorPanel"

    local PANEL = {}

    local PLANE_GRID_COLOR = Color(115, 225, 255, 100)
    local PLANE_BORDER_COLOR = Color(150, 240, 255, 210)
    local PLANE_BORDER_GLOW_COLOR = Color(110, 210, 255, 90)

    local function drawPlaneGrid(center, basis, halfSize, pulse)
        local u = basis.u
        local v = basis.v
        local steps = 6

        for i = -steps, steps do
            local t = i / steps
            local lineA = center + u * (halfSize * t) + v * halfSize
            local lineB = center + u * (halfSize * t) - v * halfSize
            render.DrawLine(lineA, lineB, Color(PLANE_GRID_COLOR.r, PLANE_GRID_COLOR.g, PLANE_GRID_COLOR.b, PLANE_GRID_COLOR.a * pulse), true)

            local lineC = center + v * (halfSize * t) + u * halfSize
            local lineD = center + v * (halfSize * t) - u * halfSize
            render.DrawLine(lineC, lineD, Color(PLANE_GRID_COLOR.r, PLANE_GRID_COLOR.g, PLANE_GRID_COLOR.b, PLANE_GRID_COLOR.a * pulse), true)
        end
    end

    local function basisTo3D2DAngle(basis)
        local angle = Math.BasisToWorldAngle(basis.n, -basis.u, basis.v)
        angle:RotateAroundAxis(angle:Right(), 90)
        return angle
    end

    local function drawBlurredPlaneBorder3D2D(center, basis, halfSize, pulse)
        local scale = 0.2
        local sizePixels = (halfSize * 2) / scale
        local halfPixels = sizePixels * 0.5
        local angle = basisTo3D2DAngle(basis)
        local origin = center + basis.n * 0.15

        cam.IgnoreZ(true)
        cam.Start3D2D(origin, angle, scale)
            local glowBaseAlpha = PLANE_BORDER_GLOW_COLOR.a * pulse
            local blurOffsets = { 1, 2, 3, 4 }

            for i, offset in ipairs(blurOffsets) do
                local falloff = (5 - i) / 4
                local alpha = math.Clamp(glowBaseAlpha * falloff, 0, 255)
                surface.SetDrawColor(PLANE_BORDER_GLOW_COLOR.r, PLANE_BORDER_GLOW_COLOR.g, PLANE_BORDER_GLOW_COLOR.b, alpha)
                surface.DrawOutlinedRect(-halfPixels - offset, -halfPixels - offset, sizePixels + offset * 2, sizePixels + offset * 2)
            end

            local borderAlpha = math.Clamp(PLANE_BORDER_COLOR.a * pulse, 0, 255)
            surface.SetDrawColor(PLANE_BORDER_COLOR.r, PLANE_BORDER_COLOR.g, PLANE_BORDER_COLOR.b, borderAlpha)
            surface.DrawOutlinedRect(-halfPixels, -halfPixels, sizePixels, sizePixels)
        cam.End3D2D()
        cam.IgnoreZ(false)
    end

    function MODE.DrawSourceOverlay(sourceConnector)
        if not sourceConnector or not sourceConnector.hitPosWorld or not sourceConnector.worldBasis then
            return
        end

        local center = sourceConnector.hitPosWorld
        local normal = sourceConnector.worldBasis.n
        local basis = Math.BuildBasis(normal, sourceConnector.worldBasis.u)

        local eyeDistance = EyePos():Distance(center)
        local planeSize = math.Clamp(eyeDistance * 0.18, 96, 420)
        local halfSize = planeSize * 0.5
        local pulse = 0.78 + 0.22 * math.sin(CurTime() * 2.2)

        drawPlaneGrid(center, basis, halfSize, pulse)

        local borderHalfSize = halfSize
        drawBlurredPlaneBorder3D2D(center, basis, borderHalfSize, pulse)
    end

    function PANEL:Init()
        self:DockPadding(0, 0, 0, 0)

        local scroll = vgui.Create("DScrollPanel", self)
        scroll:Dock(FILL)

        local infoForm = vgui.Create("DForm", scroll)
        infoForm:Dock(TOP)
        infoForm:SetName("Mirror")
        infoForm:Help("Click any surface to define a mirror plane")
        infoForm:Help("Then click entities to mirror them around that plane")

        local actionForm = vgui.Create("DForm", scroll)
        actionForm:Dock(TOP)
        actionForm:SetName("Options")
        actionForm:CheckBox("Freeze", "micron_freeze_prop")
        Utils.AttachSectionResetButton(actionForm, MODE.ClientConVarDefaults, {
            "freeze_prop"
        })

        local keybindForm = vgui.Create("DForm", scroll)
        keybindForm:Dock(TOP)
        keybindForm:SetName("Keybinds")
        keybindForm:Help("LMB #1: set mirror plane (world or entity)")
        keybindForm:Help("LMB: duplicate + mirror")
        keybindForm:Help("Shift+LMB: mirror original")
        keybindForm:Help("Use+RMB: clear mirror plane")
    end

    function PANEL:GetPreferredHeight()
        return 420
    end

    vgui.Register(MODE.PanelClass, PANEL, "DPanel")
end

Registry.Register("mirror", MODE)
