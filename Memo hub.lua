print("[MEMO] Script loading…")

local P=game:GetService("Players").LocalPlayer
local C=P.Character or P.CharacterAdded:Wait()
local R=C:WaitForChild("HumanoidRootPart")
local H=C:WaitForChild("Humanoid")
local RS=game:GetService("RunService")
local UIS=game:GetService("UserInputService")
local TS=game:GetService("TeleportService")
local Lighting=game:GetService("Lighting")
local VIM=game:GetService("VirtualInputManager")
local container=workspace:WaitForChild("RenderedMovingAnimals")

local target=nil
local targetIsPlot=false
local carpetReady=false
local buttons={}
local plotButtons={}
local attachment0,attachment1,alignPos
local spamming=false
local spamThread=nil
local chasing=false
local espEnabled=false
local espCache={}

-- ===================== DEBUG =====================
local CLONE_DEBUG = true
local function diag(...) if CLONE_DEBUG then print("[CLONE]", ...) end end
-- =================================================

-- ===================== ANTI-STUCK (rolling window) =====================
local posHistory       = {}
local STUCK_WINDOW     = 1.6
local STUCK_THRESHOLD  = 3.0
local STUCK_VELOCITY   = 1.5
local cloneCooldown    = 0
local CLONE_COOLDOWN   = 6

local function recordPos(pos)
	table.insert(posHistory, {t=tick(), p=pos})
	while #posHistory > 0 and tick() - posHistory[1].t > STUCK_WINDOW do
		table.remove(posHistory, 1)
	end
end

local function resetStuckHistory()
	posHistory = {}
end

local function isStuck()
	if #posHistory < 5 then return false end
	local first = posHistory[1]
	local last  = posHistory[#posHistory]
	local totalMoved = (last.p - first.p).Magnitude
	local elapsed = last.t - first.t
	if elapsed < STUCK_WINDOW * 0.75 then return false end
	if totalMoved >= STUCK_THRESHOLD then return false end
	local char = P.Character
	if not char then return false end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return false end
	if hrp.AssemblyLinearVelocity.Magnitude > STUCK_VELOCITY then return false end
	return true
end

local function wallAhead()
	local char = P.Character
	if not char then return false end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return false end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then return false end
	local dir = hum.MoveDirection
	if dir.Magnitude < 0.1 then return false end
	local ray = RaycastParams.new()
	ray.FilterType = Enum.RaycastFilterType.Exclude
	ray.FilterDescendantsInstances = {char}
	local hit = workspace:Raycast(hrp.Position, dir.Unit * 5, ray)
	return hit ~= nil
end

-- ===================== BRAINROT FILTER =====================
local BLACKLIST = {
	"friend","panel","cash","multiplier","delivery","hitbox",
	"spawn","target","steal","button","gui","shop","pad",
	"zone","sign","prompt","attachment","trigger","remote",
	"script","value","product","sell","collect","reward",
	"base","floor","wall","ground","mainroot","main_root",
	"plot","hitbox","spawnanimal","deliveryhitbox","stealhitbox",
	"money","coin","decal","texture","sound","effect","particle",
	"light","pointlight","spotlight","camera","viewport",
}

local function isBlacklisted(name)
	if not name or name == "" then return true end
	local lower = name:lower()
	if lower == "model" then return true end
	for _, word in ipairs(BLACKLIST) do
		if lower:find(word, 1, true) then return true end
	end
	return false
end

local function isBrainrot(instance)
	if not instance:IsA("Model") then return false end
	if not instance:FindFirstChildWhichIsA("BasePart") then return false end
	if isBlacklisted(instance.Name) then return false end
	return true
end

local function addNumbers(entries)
	local counts, seen = {}, {}
	for _, e in ipairs(entries) do
		local n = e.instance.Name
		counts[n] = (counts[n] or 0) + 1
	end
	for _, e in ipairs(entries) do
		local n = e.instance.Name
		if counts[n] > 1 then
			seen[n] = (seen[n] or 0) + 1
			e.displayName = n.." ("..seen[n]..")"
		else
			e.displayName = n
		end
	end
	return entries
end

-- ===================== HUMAN-LIKE HELPERS =====================
local function randFloat(min, max) return min + math.random() * (max - min) end
local function humanWait(min, max) task.wait(randFloat(min, max)) end
-- =============================================================

-- ===================== PURCHASE FINDER / CLICKER (UNDETECTED) =====================
local KEYWORDS = {"purchase"}
local function textMatches(text)
	if not text or text == "" then return false end
	local t = text:lower()
	for _, kw in ipairs(KEYWORDS) do
		if t:find(kw, 1, true) then return true end
	end
	return false
end

local promptCache = {}
local lastCacheRefresh = 0
local CACHE_REFRESH_INTERVAL = 2

local function refreshPromptCache()
	local newCache, count = {}, 0
	for _, v in ipairs(workspace:GetDescendants()) do
		if v:IsA("ProximityPrompt") and textMatches(v.ActionText) then
			local part = v.Parent and v.Parent.Parent
			if part and part:IsA("BasePart") then
				count += 1
				newCache[count] = {prompt=v, part=part}
			end
		end
	end
	promptCache = newCache
end

-- Fires one prompt with a human-like rhythm
local function fireOnePrompt(prompt)
	pcall(fireproximityprompt, prompt)
	-- Humans can't fire 20x per second — small stagger
	task.wait(randFloat(0.05, 0.14))
	pcall(fireproximityprompt, prompt)
end

-- Fires a random subset of in-range prompts instead of all of them every cycle.
-- This breaks the "every prompt fires every tick" pattern that anti-cheat watches for.
local function firePromptsHumanLike()
	C = P.Character
	if not C then return end
	R = C:FindFirstChild("HumanoidRootPart")
	if not R then return end
	local pos = R.Position

	-- Collect in-range prompts first
	local inRange = {}
	for i = 1, #promptCache do
		local entry = promptCache[i]
		if entry.prompt.Parent and entry.part.Parent then
			local reach = entry.prompt.MaxActivationDistance + 12
			if (entry.part.Position - pos).Magnitude <= reach then
				table.insert(inRange, entry.prompt)
			end
		end
	end
	if #inRange == 0 then return end

	-- Pick how many to fire this cycle (30%-90% of what's available)
	local count = math.max(1, math.floor(#inRange * randFloat(0.3, 0.9)))
	-- Shuffle
	for i = #inRange, 2, -1 do
		local j = math.random(i)
		inRange[i], inRange[j] = inRange[j], inRange[i]
	end

	for i = 1, count do
		fireOnePrompt(inRange[i])
	end
end

local function spamPurchase()
	spamming = true
	if spamThread then return end
	spamThread = task.spawn(function()
		refreshPromptCache()
		while spamming do
			local now = tick()
			if now - lastCacheRefresh >= CACHE_REFRESH_INTERVAL then
				refreshPromptCache()
				lastCacheRefresh = now
			end

			firePromptsHumanLike()

			-- Longer, randomized gap between cycles so it's not a steady 20Hz heartbeat
			task.wait(randFloat(0.35, 0.85))

			-- Occasional longer pause — like a human looking around / doing something else
			if math.random() < 0.12 then
				task.wait(randFloat(1.5, 3.2))
			end
		end
		spamThread = nil
	end)
end

local function stopSpam()
	spamming = false
	spamThread = nil
end
-- ==================================================================================

local MOVE_SPEED  = 120
local MOVE_SMOOTH = 35

local function setupAlign()
	if attachment0 then attachment0:Destroy() attachment0=nil end
	if attachment1 then attachment1:Destroy() attachment1=nil end
	if alignPos then alignPos:Destroy() alignPos=nil end
	C=P.Character or P.CharacterAdded:Wait()
	R=C:WaitForChild("HumanoidRootPart")
	local part=Instance.new("Part")
	part.Anchored=true part.CanCollide=false part.Transparency=1
	part.Size=Vector3.new(1,1,1) part.Parent=workspace part.Name="_tp"
	attachment0=Instance.new("Attachment",R)
	attachment1=Instance.new("Attachment",part)
	alignPos=Instance.new("AlignPosition")
	alignPos.Attachment0=attachment0
	alignPos.Attachment1=attachment1
	alignPos.MaxForce=math.huge
	alignPos.MaxVelocity=MOVE_SPEED
	alignPos.Responsiveness=MOVE_SMOOTH
	alignPos.RigidityEnabled=false
	alignPos.Parent=R
	return part
end

local anchorPart=nil

local function stopChasing()
	chasing=false carpetReady=false target=nil targetIsPlot=false
	if alignPos then alignPos:Destroy() alignPos=nil end
	if attachment0 then attachment0:Destroy() attachment0=nil end
	if attachment1 then attachment1:Destroy() attachment1=nil end
	if anchorPart then anchorPart:Destroy() anchorPart=nil end
	local char=P.Character
	if char then
		local hum=char:FindFirstChildOfClass("Humanoid")
		if hum then
			local eq=char:FindFirstChild("Flying Carpet")
			if eq then
				pcall(function() eq:Deactivate() end)
				pcall(function() hum:UnequipTools() end)
			end
		end
	end
	resetStuckHistory()
end

local function activateCarpet()
	resetStuckHistory()
	carpetReady=false
	C=P.Character or P.CharacterAdded:Wait()
	R=C:WaitForChild("HumanoidRootPart")
	H=C:WaitForChild("Humanoid")
	local tool=P.Backpack:FindFirstChild("Flying Carpet") or C:FindFirstChild("Flying Carpet")
	if not tool then carpetReady=true return end
	H:EquipTool(tool)
	task.wait(0.5)
	local eq=C:FindFirstChild("Flying Carpet")
	if eq then eq:Activate() end
	task.wait(0.8)
	if not chasing then return end
	anchorPart=setupAlign()
	carpetReady=true
end

local function getAnimalRoot(animal)
	local hrp=animal:FindFirstChild("HumanoidRootPart")
	if hrp then return hrp end
	local biggest,bigSize=nil,0
	for _,v in ipairs(animal:GetDescendants()) do
		if v:IsA("BasePart") and not v.Anchored then
			local s=v.Size.Magnitude
			if s>bigSize then bigSize=s biggest=v end
		end
	end
	return biggest or animal:FindFirstChildWhichIsA("BasePart")
end

local function getObstacleAvoidOffset()
	C=P.Character
	if not C then return Vector3.zero end
	R=C:FindFirstChild("HumanoidRootPart")
	if not R then return Vector3.zero end
	local ray=RaycastParams.new()
	ray.FilterType=Enum.RaycastFilterType.Exclude
	local excluded={C}
	for _,pl in ipairs(game:GetService("Players"):GetPlayers()) do
		if pl.Character then table.insert(excluded,pl.Character) end
	end
	for _,v in ipairs(container:GetChildren()) do table.insert(excluded,v) end
	ray.FilterDescendantsInstances=excluded
	local dirs={
		Vector3.new(1,0,0),Vector3.new(-1,0,0),
		Vector3.new(0,0,1),Vector3.new(0,0,-1),
		Vector3.new(1,0,1).Unit,Vector3.new(-1,0,-1).Unit,
	}
	local avoidDir=Vector3.zero
	for _,d in ipairs(dirs) do
		local result=workspace:Raycast(R.Position,d*4,ray)
		if result then avoidDir=avoidDir-d end
	end
	if avoidDir.Magnitude>0 then
		return (avoidDir.Unit+Vector3.new(0,1,0))*6
	end
	return Vector3.zero
end

-- ===================== QUANTUM CLONER =====================
local function hasExistingClone()
	local tag = tostring(P.UserId).."_Clone"
	for _, v in ipairs(workspace:GetChildren()) do
		if v.Name == tag then return true end
	end
	return false
end

local function humanTap()
	local cam = workspace.CurrentCamera
	if not cam then return false end
	local vp = cam.ViewportSize
	local cx = vp.X / 2
	local cy = vp.Y / 2
	local x = math.floor(cx + randFloat(-20, 20))
	local y = math.floor(cy + randFloat(-20, 20))
	if VIM then
		local ok = pcall(function()
			VIM:SendMouseButtonEvent(x, y, 0, true, game, 1)
			task.wait(randFloat(0.03, 0.09))
			VIM:SendMouseButtonEvent(x, y, 0, false, game, 1)
		end)
		if ok then return true end
	end
	pcall(function()
		UIS:InputBegan(Enum.UserInputType.Touch, false)
	end)
	return false
end

local function humanTapSeries(count)
	for i = 1, count do
		humanTap()
		if i < count then humanWait(0.10, 0.28) end
	end
end

-- Find the QuantumCloner GUI robustly
local function findQuantumClonerGui()
	local pg = P:FindFirstChild("PlayerGui")
	if not pg then return nil, "no_playergui" end

	local tf = pg:FindFirstChild("ToolsFrames")
	if tf then
		local qc = tf:FindFirstChild("QuantumCloner")
		if qc then
			diag("GUI found via ToolsFrames.QuantumCloner")
			return qc, "toolsframes"
		end
	end

	for _, d in ipairs(pg:GetDescendants()) do
		if d.Name == "QuantumCloner" then
			diag("GUI found via broad search:", d:GetFullName())
			return d, "broad_search"
		end
	end
	return nil, "not_found"
end

-- Find the Change-With-Clone button (name-first)
local function findCloneButton(gui)
	local direct = gui:FindFirstChild("TeleportToClone", true)
	if direct and direct:IsA("GuiButton") then
		diag("Found by name: TeleportToClone")
		return direct
	end

	for _, d in ipairs(gui:GetDescendants()) do
		if d:IsA("GuiButton") then
			local txt = (d.Text or ""):lower():gsub("%s+", " ")
			if txt:find("change with clone")
			or txt:find("change with")
			or txt:find("change clone")
			or txt:find("teleport to clone")
			or txt == "change" then
				diag("Found by text:", d.Name, "text:", d.Text)
				return d
			end
		end
	end

	for _, d in ipairs(gui:GetDescendants()) do
		if d:IsA("GuiButton") then
			for _, c in ipairs(d:GetDescendants()) do
				if c:IsA("TextLabel") then
					local txt = (c.Text or ""):lower()
					if txt:find("change") or txt:find("clone") then
						diag("Found by child label:", d.Name, "label:", c.Text)
						return d
					end
				end
			end
		end
	end

	for _, n in ipairs({"ChangeWithClone","ChangeClone","CreateClone","Clone","Change","Teleport"}) do
		local b = gui:FindFirstChild(n, true)
		if b and b:IsA("GuiButton") then
			diag("Found by name fallback:", n)
			return b
		end
	end

	diag("No button matched — listing every GuiButton under the GUI:")
	for _, d in ipairs(gui:GetDescendants()) do
		if d:IsA("GuiButton") then
			diag(string.format("  %s  name=%q  text=%q",
				d.ClassName, d.Name, tostring(d.Text)))
		end
	end
	return nil
end

-- Human-like click: fires signals AND clicks button's real screen position
local function humanClickButton(btn)
	pcall(function() btn.MouseButton1Down:Fire() end)
	task.wait(randFloat(0.03, 0.09))
	pcall(function() btn.MouseButton1Up:Fire() end)
	task.wait(randFloat(0.02, 0.06))
	pcall(function() btn.MouseButton1Click:Fire() end)
	pcall(function() btn:Activate() end)

	if VIM then
		local ok, pos, size = pcall(function()
			return btn.AbsolutePosition, btn.AbsoluteSize
		end)
		if ok and pos and size then
			local x = math.floor(pos.X + size.X / 2)
			local y = math.floor(pos.Y + size.Y / 2)
			task.wait(0.08)
			local touchMode = UIS.TouchEnabled
			pcall(function()
				if touchMode and VIM.SendTouchEvent then
					VIM:SendTouchEvent(Enum.UserInputType.Touch, Vector3.new(x, y, 0), true)
					task.wait(0.05)
					VIM:SendTouchEvent(Enum.UserInputType.Touch, Vector3.new(x, y, 0), false)
				else
					VIM:SendMouseButtonEvent(x, y, 0, true, game, 1)
					task.wait(0.05)
					VIM:SendMouseButtonEvent(x, y, 0, false, game, 1)
				end
			end)
			diag("VIM clicked at", x, y)
		end
	end
end

local function runCloneSequence(opts)
	opts = opts or {}
	local silent = opts.silent
	local skipExisting = opts.skipExisting ~= false

	if hasExistingClone() and skipExisting then
		diag("Skipped — clone already exists")
		return false, "clone_exists"
	end

	local char = P.Character
	if not char then return false, "no_character" end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then return false, "no_humanoid" end

	local tool = P.Backpack:FindFirstChild("Quantum Cloner")
		or char:FindFirstChild("Quantum Cloner")
	if not tool then
		if not silent then warn("[CLONE] No Quantum Cloner in backpack") end
		return false, "no_tool"
	end

	humanWait(0.15, 0.55)

	if tool.Parent == P.Backpack then
		hum:EquipTool(tool)
		humanWait(0.35, 0.65)
	end

	local equipped = char:FindFirstChild("Quantum Cloner")
	if not equipped then return false, "equip_failed" end
	diag("Equipped tool")

	pcall(function() equipped:Activate() end)
	humanWait(0.15, 0.30)

	humanTapSeries(math.random(2, 4))
	humanWait(0.20, 0.45)

	local qc, srcPath = findQuantumClonerGui()
	if not qc then
		diag("GUI not found after equip + taps. Reason:", srcPath)
		local t0 = tick()
		repeat
			task.wait(0.2)
			qc, srcPath = findQuantumClonerGui()
		until qc or tick() - t0 > 3
		if not qc then
			if not silent then warn("[CLONE] QuantumCloner GUI never appeared") end
			return false, "no_cloner_gui"
		end
	end
	diag("GUI path used:", srcPath)

	local t0 = tick()
	while tick() - t0 < 2.5 do
		if qc.Visible then break end
		task.wait(0.1)
	end
	if not qc.Visible then
		diag("GUI exists but Visible = false — clone may not exist yet")
	end
	humanWait(0.25, 0.55)

	local btn = findCloneButton(qc)
	if not btn then
		if not silent then warn("[CLONE] Could not find Change-With-Clone button") end
		return false, "no_button"
	end
	diag("Clicking button:", btn.Name, "text:", tostring(btn.Text))

	humanClickButton(btn)
	humanWait(0.60, 0.95)

	if char:FindFirstChild("Quantum Cloner") then
		pcall(function() hum:UnequipTools() end)
	end

	diag("Clone sequence finished")
	return true
end

local function useQuantumCloner()
	if tick() - cloneCooldown < CLONE_COOLDOWN then return end
	cloneCooldown = tick()
	task.spawn(function()
		local ok = runCloneSequence({silent=true, skipExisting=true})
		if ok then
			local char = P.Character
			if char and char:FindFirstChild("HumanoidRootPart") then
				resetStuckHistory()
				recordPos(char.HumanoidRootPart.Position)
			end
		end
	end)
end
-- ============================================================

-- ===================== AUTO REJOIN / KICK =====================
local KICK_MSG = "You have been kicked by memo"
local AUTOEXEC_FOLDERS = {
	"autoexec","autoexe","autoexecu","autoexecute",
	"AutoExec","AutoExecute","AutoExe","AutoExecu",
	"autoexecutes","autoexecution","autoload","auto_load",
	"startup","Startup","scripts","Scripts","workspace","Workspace",
}

local function getSelfSource()
	if getscriptbytecode and decompile then
		local ok, bc = pcall(getscriptbytecode)
		if ok and bc then
			local ok2, src = pcall(decompile, bc)
			if ok2 and src and #src > 0 then return src end
		end
	end
	if debug and debug.getinfo then
		local ok, info = pcall(debug.getinfo, 1, "s")
		if ok and info and info.source then
			local src = info.source
			if type(src) == "string" then
				if src:sub(1,1) == "@" then
					if readfile then
						local ok2, data = pcall(readfile, src:sub(2))
						if ok2 and data then return data end
					end
				elseif src:sub(1,1) == "=" then
					return src:sub(2)
				else
					return src
				end
			end
		end
	end
	return nil
end

local function saveToAutoExec(source)
	if not source or not writefile then return false end
	for _, folderName in ipairs(AUTOEXEC_FOLDERS) do
		pcall(function()
			if isfolder and not isfolder(folderName) then makefolder(folderName) end
			writefile(folderName.."/memo_autoexec.lua", source)
		end)
	end
	pcall(function() writefile("memo_autoexec.lua", source) end)
	return true
end

local function rejoin()
	local source = getSelfSource()
	saveToAutoExec(source)
	if queue_on_teleport and source then
		pcall(function() queue_on_teleport(source) end)
	end
	if not pcall(function() TS:Teleport(game.PlaceId) end) then
		pcall(function() TS:TeleportAsync(game.PlaceId, {P}) end)
	end
end

local function kickSelf()
	pcall(function() P:Kick(KICK_MSG) end)
	task.wait(0.3)
	pcall(function() P.Parent = nil end)
end

-- ===================== GAME SETTINGS =====================
local ORIGINAL_FOV = workspace.CurrentCamera and workspace.CurrentCamera.FieldOfView or 70
local state = {fov=ORIGINAL_FOV, fpsBoost=false, fullbright=false, noFog=false}

local function applyFov(value)
	state.fov = math.clamp(value, 50, 120)
	local cam = workspace.CurrentCamera
	if cam then cam.FieldOfView = state.fov end
end

local function applyFpsBoost(enabled)
	state.fpsBoost = enabled
	if enabled then
		pcall(function() settings("Rendering","QualityLevel",1) end)
		pcall(function() settings("Rendering","SavedQualityLevel",1) end)
		pcall(function() settings("Rendering","MeshPartDetailLevel","DistanceBased") end)
		for _, v in ipairs(game:GetDescendants()) do
			if v:IsA("Decal") or v:IsA("Texture") then
				v.Transparency = 1
			elseif v:IsA("ParticleEmitter") or v:IsA("Trail")
				or v:IsA("Smoke") or v:IsA("Fire") or v:IsA("Sparkles") then
				v.Enabled = false
			end
		end
	else
		pcall(function() settings("Rendering","QualityLevel",10) end)
		pcall(function() settings("Rendering","SavedQualityLevel",10) end)
		pcall(function() settings("Rendering","MeshPartDetailLevel","Disabled") end)
	end
end

local function applyFullbright(enabled)
	state.fullbright = enabled
	if enabled then
		Lighting.Brightness = 3
		Lighting.ClockTime = 14
		Lighting.GlobalShadows = false
		Lighting.OutdoorAmbient = Color3.fromRGB(178,178,178)
		Lighting.Ambient = Color3.fromRGB(178,178,178)
	else
		Lighting.Brightness = 2
		Lighting.GlobalShadows = true
		Lighting.OutdoorAmbient = Color3.fromRGB(70,70,70)
		Lighting.Ambient = Color3.fromRGB(70,70,70)
	end
end

local function applyNoFog(enabled)
	state.noFog = enabled
	if enabled then
		Lighting.FogEnd = 1e6
		Lighting.FogStart = 1e6
	else
		Lighting.FogEnd = 100000
		Lighting.FogStart = 0
	end
end

local function resetAll()
	applyFov(ORIGINAL_FOV)
	if state.fpsBoost then applyFpsBoost(false) end
	if state.fullbright then applyFullbright(false) end
	if state.noFog then applyNoFog(false) end
	state.fpsBoost=false state.fullbright=false state.noFog=false
end

-- ===================== GUI HELPERS =====================
local function getGuiParent()
	if gethui then
		local ok, h = pcall(gethui)
		if ok and h then
			local test = Instance.new("ScreenGui")
			local ok2 = pcall(function() test.Parent = h end)
			if ok2 and test.Parent == h then
				test:Destroy()
				print("[MEMO] GUI parent: gethui()")
				return h
			end
			test:Destroy()
		end
	end
	local pg = P:FindFirstChildOfClass("PlayerGui")
	if not pg then pg = P:WaitForChild("PlayerGui", 5) end
	if pg then
		print("[MEMO] GUI parent: PlayerGui")
		return pg
	end
	warn("[MEMO] No GUI parent available!")
	return nil
end

local GUI_PARENT = getGuiParent()

local function makeDraggable(frame, handle)
	local dragging, dragStart, startPos
	handle.InputBegan:Connect(function(i)
		if i.UserInputType==Enum.UserInputType.MouseButton1
		or i.UserInputType==Enum.UserInputType.Touch then
			dragging=true dragStart=i.Position startPos=frame.Position
		end
	end)
	UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType==Enum.UserInputType.MouseMovement
		or i.UserInputType==Enum.UserInputType.Touch) then
			local d=i.Position-dragStart
			frame.Position=UDim2.new(
				startPos.X.Scale, startPos.X.Offset+d.X,
				startPos.Y.Scale, startPos.Y.Offset+d.Y)
		end
	end)
	UIS.InputEnded:Connect(function(i)
		if i.UserInputType==Enum.UserInputType.MouseButton1
		or i.UserInputType==Enum.UserInputType.Touch then
			dragging=false
		end
	end)
end

local function makeFrame(titleText, size, position)
	local gui = Instance.new("ScreenGui")
	gui.Name = "Memo_"..titleText:gsub("[^%w]","").."_"..tostring(math.random(100000,999999))
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 999
	gui.Parent = GUI_PARENT

	local frame = Instance.new("Frame")
	frame.Size = size
	frame.Position = position
	frame.BackgroundColor3 = Color3.fromRGB(20,20,20)
	frame.BorderSizePixel = 0
	frame.Parent = gui
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0,8)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1,0,0,26)
	title.BackgroundColor3 = Color3.fromRGB(35,35,35)
	title.TextColor3 = Color3.fromRGB(255,255,255)
	title.Text = titleText
	title.Font = Enum.Font.GothamBold
	title.TextSize = 11
	title.Parent = frame
	Instance.new("UICorner", title).CornerRadius = UDim.new(0,8)

	makeDraggable(frame, title)
	return gui, frame
end

local function makeButton(parent, text, size, position, color, textSize)
	local btn = Instance.new("TextButton")
	btn.Size = size
	btn.Position = position
	btn.BackgroundColor3 = color
	btn.TextColor3 = Color3.fromRGB(255,255,255)
	btn.Text = text
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = textSize or 12
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = true
	btn.TextTruncate = Enum.TextTruncate.AtEnd
	btn.Parent = parent
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0,6)
	return btn
end

local function shortPlot(name) return name:sub(1, 6) end

-- ===================== ESP SYSTEM =====================
local function getAdornee(instance)
	if instance.PrimaryPart then return instance.PrimaryPart end
	local hrp = instance:FindFirstChild("HumanoidRootPart", true)
	if hrp then return hrp end
	local biggest, size = nil, 0
	for _, v in ipairs(instance:GetDescendants()) do
		if v:IsA("BasePart") then
			local s = v.Size.Magnitude
			if s > size then size = s biggest = v end
		end
	end
	return biggest
end

local function clearESP()
	for inst, data in pairs(espCache) do
		pcall(function() data.billboard:Destroy() end)
		pcall(function() data.highlight:Destroy() end)
		espCache[inst] = nil
	end
	espCache = {}
end

local function updateESP(entries)
	if not espEnabled then clearESP() return end
	local currentSet = {}
	for _, e in ipairs(entries) do currentSet[e.instance] = e.displayName end
	for inst, data in pairs(espCache) do
		if not currentSet[inst] or not inst.Parent then
			pcall(function() data.billboard:Destroy() end)
			pcall(function() data.highlight:Destroy() end)
			espCache[inst] = nil
		end
	end
	for inst, displayName in pairs(currentSet) do
		if inst.Parent then
			if not espCache[inst] then
				local adornee = getAdornee(inst)
				if adornee then
					local bb = Instance.new("BillboardGui")
					bb.Name="MemoESP"
					bb.Size=UDim2.new(0,220,0,22)
					bb.StudsOffset=Vector3.new(0,4,0)
					bb.AlwaysOnTop=true
					bb.LightInfluence=0
					bb.Adornee=adornee
					bb.Parent=adornee

					local lbl = Instance.new("TextLabel")
					lbl.Size=UDim2.new(1,0,1,0)
					lbl.BackgroundTransparency=1
					lbl.TextColor3=Color3.fromRGB(120,255,120)
					lbl.TextStrokeTransparency=0
					lbl.TextStrokeColor3=Color3.new(0,0,0)
					lbl.Font=Enum.Font.GothamBold
					lbl.TextSize=14
					lbl.Text=displayName
					lbl.Parent=bb

					local hl = Instance.new("Highlight")
					hl.Name="MemoESP"
					hl.Adornee=inst
					hl.FillColor=Color3.fromRGB(0,255,0)
					hl.FillTransparency=0.65
					hl.OutlineColor=Color3.fromRGB(255,255,255)
					hl.OutlineTransparency=0
					hl.DepthMode=Enum.HighlightDepthMode.AlwaysOnTop
					hl.Parent=inst

					espCache[inst]={billboard=bb, highlight=hl, label=lbl}
				end
			else
				local data = espCache[inst]
				if data.label.Text ~= displayName then
					data.label.Text = displayName
				end
			end
		end
	end
end

local function bindTeleportButton(btn, instance, isPlot)
	btn.MouseButton1Click:Connect(function()
		if target == instance and chasing then
			stopChasing()
			btn.BackgroundColor3 = Color3.fromRGB(40,40,40)
			return
		end
		if chasing then stopChasing() end
		for _, b in pairs(buttons) do b.BackgroundColor3 = Color3.fromRGB(40,40,40) end
		for _, data in pairs(plotButtons) do data.btn.BackgroundColor3 = Color3.fromRGB(40,40,40) end
		btn.BackgroundColor3 = Color3.fromRGB(60,100,60)
		target = instance
		targetIsPlot = isPlot or false
		chasing = true
		task.spawn(activateCarpet)
	end)
end

if not GUI_PARENT then
	warn("[MEMO] Cannot create GUI — no parent available.")
else

	-- ===================== UI 1: CARPET BRAINROTS =====================
	local mainGui, mainFrame = makeFrame(
		"Carpet Brainrots",
		UDim2.new(0,200,0,340),
		UDim2.new(0,10,0.5,-170)
	)

	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.new(1,-10,1,-80)
	scroll.Position = UDim2.new(0,5,0,30)
	scroll.BackgroundTransparency = 1
	scroll.ScrollBarThickness = 3
	scroll.BorderSizePixel = 0
	scroll.CanvasSize = UDim2.new(0,0,0,0)
	scroll.Parent = mainFrame

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0,4)
	layout.Parent = scroll

	local spamBtn = makeButton(mainFrame, "SPAM PURCHASE: OFF",
		UDim2.new(1,-10,0,28), UDim2.new(0,5,1,-60), Color3.fromRGB(40,80,40))
	local stopBtn = makeButton(mainFrame, "STOP ALL",
		UDim2.new(1,-10,0,28), UDim2.new(0,5,1,-28), Color3.fromRGB(60,60,60), 11)

	spamBtn.MouseButton1Click:Connect(function()
		if spamming then
			stopSpam()
			spamBtn.Text = "SPAM PURCHASE: OFF"
			spamBtn.BackgroundColor3 = Color3.fromRGB(40,80,40)
		else
			spamPurchase()
			spamBtn.Text = "SPAM PURCHASE: ON"
			spamBtn.BackgroundColor3 = Color3.fromRGB(80,40,40)
		end
	end)

	stopBtn.MouseButton1Click:Connect(function()
		stopSpam() stopChasing()
		spamBtn.Text = "SPAM PURCHASE: OFF"
		spamBtn.BackgroundColor3 = Color3.fromRGB(40,80,40)
		for _, b in pairs(buttons) do b.BackgroundColor3 = Color3.fromRGB(40,40,40) end
		for _, data in pairs(plotButtons) do data.btn.BackgroundColor3 = Color3.fromRGB(40,40,40) end
	end)

	local function refreshCanvas()
		scroll.CanvasSize = UDim2.new(0,0,0,layout.AbsoluteContentSize.Y+8)
	end

	local function removeBtn(name)
		if buttons[name] then
			buttons[name]:Destroy()
			buttons[name] = nil
			refreshCanvas()
		end
	end

	local function makeBtn(animal, displayName)
		local name = animal.Name
		if buttons[name] then
			buttons[name].Text = displayName or name
			return
		end
		local btn = makeButton(scroll, displayName or name,
			UDim2.new(1,-6,0,26), UDim2.new(0,0,0,0),
			Color3.fromRGB(40,40,40), 11)
		btn.Font = Enum.Font.Gotham
		buttons[name] = btn
		refreshCanvas()
		bindTeleportButton(btn, animal, false)
	end

	local function refreshCarpetList()
		local entries = {}
		for _, v in ipairs(container:GetChildren()) do
			table.insert(entries, {instance=v})
		end
		addNumbers(entries)
		local existing = {}
		for _, e in ipairs(entries) do
			existing[e.instance.Name] = true
			makeBtn(e.instance, e.displayName)
		end
		for name in pairs(buttons) do
			if not existing[name] then removeBtn(name) end
		end
	end

	for _, v in ipairs(container:GetChildren()) do makeBtn(v) end
	container.ChildAdded:Connect(function() refreshCarpetList() end)
	container.ChildRemoved:Connect(function(v)
		if target == v then stopChasing() end
		removeBtn(v.Name)
	end)

	task.spawn(function()
		while task.wait(2) do refreshCarpetList() end
	end)
	-- =================================================================

	-- ===================== UI 2: BRAINROTS (PLOTS) =====================
	local plotGui, plotFrame = makeFrame(
		"Brainrots",
		UDim2.new(0,220,0,340),
		UDim2.new(0,220,0.5,-170)
	)

	local espBtn = makeButton(plotFrame, "BRAINROT ESP: OFF",
		UDim2.new(1,-10,0,26), UDim2.new(0,5,0,30), Color3.fromRGB(50,50,50), 11)

	local plotCountLbl = Instance.new("TextLabel")
	plotCountLbl.Size = UDim2.new(1,-10,0,14)
	plotCountLbl.Position = UDim2.new(0,5,0,60)
	plotCountLbl.BackgroundTransparency = 1
	plotCountLbl.TextColor3 = Color3.fromRGB(180,180,180)
	plotCountLbl.Text = "Scanning plots…"
	plotCountLbl.Font = Enum.Font.Gotham
	plotCountLbl.TextSize = 10
	plotCountLbl.TextXAlignment = Enum.TextXAlignment.Left
	plotCountLbl.Parent = plotFrame

	local plotScroll = Instance.new("ScrollingFrame")
	plotScroll.Size = UDim2.new(1,-10,1,-80)
	plotScroll.Position = UDim2.new(0,5,0,78)
	plotScroll.BackgroundTransparency = 1
	plotScroll.ScrollBarThickness = 3
	plotScroll.BorderSizePixel = 0
	plotScroll.CanvasSize = UDim2.new(0,0,0,0)
	plotScroll.Parent = plotFrame

	local plotLayout = Instance.new("UIListLayout")
	plotLayout.SortOrder = Enum.SortOrder.LayoutOrder
	plotLayout.Padding = UDim.new(0,4)
	plotLayout.Parent = plotScroll

	local function refreshPlotCanvas()
		plotScroll.CanvasSize = UDim2.new(0,0,0,plotLayout.AbsoluteContentSize.Y+8)
	end

	local function getPlotEntries()
		local found = {}
		local Plots = workspace:FindFirstChild("Plots")
		if not Plots then return found end
		for _, plot in ipairs(Plots:GetChildren()) do
			if plot:IsA("Model") or plot:IsA("Folder") then
				for _, child in ipairs(plot:GetChildren()) do
					if isBrainrot(child) then
						table.insert(found, {instance=child, plotName=plot.Name})
					end
				end
			end
		end
		return addNumbers(found)
	end

	local function makePlotBtn(entry)
		local instance = entry.instance
		local displayName = entry.displayName
		if plotButtons[instance] then
			plotButtons[instance].btn.Text = "["..shortPlot(entry.plotName).."] "..displayName
			return
		end
		local label = "["..shortPlot(entry.plotName).."] "..displayName
		local btn = makeButton(plotScroll, label,
			UDim2.new(1,-6,0,26), UDim2.new(0,0,0,0),
			Color3.fromRGB(40,40,40), 11)
		btn.Font = Enum.Font.Gotham
		plotButtons[instance] = {btn = btn, plotName = entry.plotName}
		refreshPlotCanvas()
		bindTeleportButton(btn, instance, true)
	end

	local function removePlotBtn(instance)
		if plotButtons[instance] then
			plotButtons[instance].btn:Destroy()
			plotButtons[instance] = nil
			refreshPlotCanvas()
		end
	end

	espBtn.MouseButton1Click:Connect(function()
		espEnabled = not espEnabled
		espBtn.Text = "BRAINROT ESP: "..(espEnabled and "ON" or "OFF")
		espBtn.BackgroundColor3 = espEnabled and Color3.fromRGB(40,100,50) or Color3.fromRGB(50,50,50)
		if not espEnabled then clearESP() end
	end)

	task.spawn(function()
		while task.wait(2) do
			local entries = getPlotEntries()
			local current = {}
			for _, entry in ipairs(entries) do
				current[entry.instance] = true
				makePlotBtn(entry)
			end
			for instance, data in pairs(plotButtons) do
				if not current[instance] or not instance.Parent then
					removePlotBtn(instance)
				end
			end
			plotCountLbl.Text = #entries.." brainrot"..(#entries == 1 and "" or "s").." in plots"
			if espEnabled then updateESP(entries) end
		end
	end)
	-- =================================================================

	-- ===================== UI 3: KICK =====================
	local kickGui, kickFrame = makeFrame(
		"Kick",
		UDim2.new(0,160,0,66),
		UDim2.new(0.5,-80,0,10)
	)
	local kickBtn = makeButton(kickFrame, "KICK",
		UDim2.new(1,-10,0,30), UDim2.new(0,5,0,30), Color3.fromRGB(120,40,40))
	kickBtn.MouseButton1Click:Connect(function() kickSelf() end)
	-- =================================================================

	-- ===================== UI 4: AUTO REJOIN =====================
	local rejoinGui, rejoinFrame = makeFrame(
		"Auto Rejoin",
		UDim2.new(0,160,0,66),
		UDim2.new(0.5,-80,0,84)
	)
	local rejoinBtn = makeButton(rejoinFrame, "AUTO REJOIN",
		UDim2.new(1,-10,0,30), UDim2.new(0,5,0,30), Color3.fromRGB(60,60,120))
	rejoinBtn.MouseButton1Click:Connect(function()
		rejoinBtn.Text = "REJOINING…"
		rejoinBtn.BackgroundColor3 = Color3.fromRGB(80,80,160)
		task.spawn(rejoin)
	end)
	-- =================================================================

	-- ===================== UI 5: CLONE =====================
	local cloneGui, cloneFrame = makeFrame(
		"Clone",
		UDim2.new(0,180,0,110),
		UDim2.new(0.5,-90,0,158)
	)

	local cloneBtn = makeButton(cloneFrame, "GET CLONE",
		UDim2.new(1,-10,0,34), UDim2.new(0,5,0,32), Color3.fromRGB(60,90,140))

	local cloneStatus = Instance.new("TextLabel")
	cloneStatus.Size = UDim2.new(1,-10,0,18)
	cloneStatus.Position = UDim2.new(0,5,0,74)
	cloneStatus.BackgroundTransparency = 1
	cloneStatus.TextColor3 = Color3.fromRGB(180,180,180)
	cloneStatus.Text = "Ready"
	cloneStatus.Font = Enum.Font.Gotham
	cloneStatus.TextSize = 10
	cloneStatus.TextXAlignment = Enum.TextXAlignment.Left
	cloneStatus.Parent = cloneFrame

	local function setCloneStatus(text, good)
		cloneStatus.Text = text
		cloneStatus.TextColor3 = good and Color3.fromRGB(150,220,150) or Color3.fromRGB(220,150,150)
	end

	cloneBtn.MouseButton1Click:Connect(function()
		if cloneBtn.Text == "WORKING…" then return end
		cloneBtn.Text = "WORKING…"
		cloneBtn.BackgroundColor3 = Color3.fromRGB(90,90,140)
		setCloneStatus("Running sequence…", true)
		task.spawn(function()
			local ok, reason = runCloneSequence({silent=false, skipExisting=false})
			if ok then
				setCloneStatus("Clone requested ✓", true)
			else
				setCloneStatus("Failed: "..tostring(reason), false)
			end
			task.wait(2)
			cloneBtn.Text = "GET CLONE"
			cloneBtn.BackgroundColor3 = Color3.fromRGB(60,90,140)
		end)
	end)
	-- =================================================================

	-- ===================== UI 6: CONFIG =====================
	local configGui, configFrame = makeFrame(
		"Config",
		UDim2.new(0,220,0,240),
		UDim2.new(0.5,-110,0,278)
	)

	local fovLbl = Instance.new("TextLabel")
	fovLbl.Size = UDim2.new(1,-10,0,16)
	fovLbl.Position = UDim2.new(0,5,0,32)
	fovLbl.BackgroundTransparency = 1
	fovLbl.TextColor3 = Color3.fromRGB(200,200,200)
	fovLbl.Text = "FOV:"
	fovLbl.Font = Enum.Font.GothamBold
	fovLbl.TextSize = 11
	fovLbl.TextXAlignment = Enum.TextXAlignment.Left
	fovLbl.Parent = configFrame

	local fovMinusBtn = makeButton(configFrame, "-",
		UDim2.new(0,30,0,26), UDim2.new(0,5,0,52), Color3.fromRGB(60,60,60), 14)
	local fovValueLbl = Instance.new("TextLabel")
	fovValueLbl.Size = UDim2.new(1,-80,0,26)
	fovValueLbl.Position = UDim2.new(0,40,0,52)
	fovValueLbl.BackgroundColor3 = Color3.fromRGB(35,35,35)
	fovValueLbl.TextColor3 = Color3.fromRGB(255,255,255)
	fovValueLbl.Text = tostring(math.floor(state.fov))
	fovValueLbl.Font = Enum.Font.GothamBold
	fovValueLbl.TextSize = 12
	fovValueLbl.Parent = configFrame
	Instance.new("UICorner", fovValueLbl).CornerRadius = UDim.new(0,6)
	local fovPlusBtn = makeButton(configFrame, "+",
		UDim2.new(0,30,0,26), UDim2.new(1,-35,0,52), Color3.fromRGB(60,60,60), 14)

	fovMinusBtn.MouseButton1Click:Connect(function()
		applyFov(state.fov - 5) fovValueLbl.Text = tostring(math.floor(state.fov))
	end)
	fovPlusBtn.MouseButton1Click:Connect(function()
		applyFov(state.fov + 5) fovValueLbl.Text = tostring(math.floor(state.fov))
	end)

	local fpsBtn = makeButton(configFrame, "FPS BOOST: OFF",
		UDim2.new(1,-10,0,28), UDim2.new(0,5,0,88), Color3.fromRGB(50,50,50))
	fpsBtn.MouseButton1Click:Connect(function()
		applyFpsBoost(not state.fpsBoost)
		fpsBtn.Text = "FPS BOOST: "..(state.fpsBoost and "ON" or "OFF")
		fpsBtn.BackgroundColor3 = state.fpsBoost and Color3.fromRGB(40,100,50) or Color3.fromRGB(50,50,50)
	end)

	local brightBtn = makeButton(configFrame, "FULLBRIGHT: OFF",
		UDim2.new(1,-10,0,28), UDim2.new(0,5,0,120), Color3.fromRGB(50,50,50))
	brightBtn.MouseButton1Click:Connect(function()
		applyFullbright(not state.fullbright)
		brightBtn.Text = "FULLBRIGHT: "..(state.fullbright and "ON" or "OFF")
		brightBtn.BackgroundColor3 = state.fullbright and Color3.fromRGB(100,90,40) or Color3.fromRGB(50,50,50)
	end)

	local fogBtn = makeButton(configFrame, "NO FOG: OFF",
		UDim2.new(1,-10,0,28), UDim2.new(0,5,0,152), Color3.fromRGB(50,50,50))
	fogBtn.MouseButton1Click:Connect(function()
		applyNoFog(not state.noFog)
		fogBtn.Text = "NO FOG: "..(state.noFog and "ON" or "OFF")
		fogBtn.BackgroundColor3 = state.noFog and Color3.fromRGB(60,70,100) or Color3.fromRGB(50,50,50)
	end)

	local resetBtn = makeButton(configFrame, "RESET ALL",
		UDim2.new(1,-10,0,28), UDim2.new(0,5,1,-36), Color3.fromRGB(100,50,50))
	resetBtn.MouseButton1Click:Connect(function()
		resetAll()
		fovValueLbl.Text = tostring(math.floor(state.fov))
		fpsBtn.Text = "FPS BOOST: OFF" fpsBtn.BackgroundColor3 = Color3.fromRGB(50,50,50)
		brightBtn.Text = "FULLBRIGHT: OFF" brightBtn.BackgroundColor3 = Color3.fromRGB(50,50,50)
		fogBtn.Text = "NO FOG: OFF" fogBtn.BackgroundColor3 = Color3.fromRGB(50,50,50)
	end)
	-- =================================================================

	print("[MEMO] All UIs created successfully.")
end

-- ===================== HEARTBEAT =====================
RS.Heartbeat:Connect(function()
	if not target or not chasing or not carpetReady or not anchorPart then return end
	if not target.Parent then stopChasing() return end

	local root = getAnimalRoot(target)
	if not root then return end
	local avoidOffset = getObstacleAvoidOffset()
	anchorPart.CFrame = CFrame.new(root.Position + avoidOffset + Vector3.new(0,-2,0))

	if targetIsPlot then
		local char = P.Character
		if not char then return end
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not hrp then return end

		recordPos(hrp.Position)

		if isStuck() and wallAhead() then
			useQuantumCloner()
			resetStuckHistory()
		end
	end
end)

-- spamPurchase()  -- disabled by default; user toggles via UI
