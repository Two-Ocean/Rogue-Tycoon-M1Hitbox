local WCS = require(game.ReplicatedStorage.wcs)

--// WCS STATUSES //--
local Attacking = _G.StatusEffects.Attacking
local noJump = _G.StatusEffects.NoJump
local AtkStun = _G.StatusEffects.AttackingStun
--// SERVICES //--
local RS = game:GetService("ReplicatedStorage")
local Debris = game.Debris
local TweenService = game:GetService("TweenService")

--// UTIL MODULES //--
local Config :ModuleScript = require(RS.Combat.Modules.Config)
local Globals :ModuleScript = _G.SharedServices.Globals
local MuchachoHitbox :ModuleScript = _G.SharedServices.MuchachoHitbox
local Packet = _G.SharedServices.Packet
local Janitor = require(RS.Services.Shared.Packages.Janitor)
-- Configuration values
local m1Config = Config.M1Fist.M1

local HitboxPacket = Packet("M1Hit", Packet.Instance)

--WCS API to register skill (refer to https://wad4444.github.io/WCS/docs/api/skill for all WCS API)
local M1 = WCS.RegisterSkill(script.Name)

--// HELPER FUNCTIONS (mostly straightforward and in the name) //--
local function hasAttribute(plr, char, attr)
	return (plr and plr:GetAttribute(attr)) or char:GetAttribute(attr)
end

local function getAnimationFolder(plr, char)
	return (hasAttribute(plr, char, "TrainedFists") and "TrainedM1Anims") or "M1Anims"
end

-- VFX function for thunder punch
local function applyThunderPunch(char, hrp)
	local pl = Instance.new("PointLight")
	pl.Parent = hrp
	pl.Color = Color3.fromRGB(26, 194, 255)
	pl.Brightness = 0
	pl.Range = 0

	TweenService:Create(pl, TweenInfo.new(0.2), {Range = 10, Brightness = 0.75}):Play()
	task.delay(0.2, function()
		TweenService:Create(pl, TweenInfo.new(0.2), {Range = 0, Brightness = 0}):Play()
	end)

	local sfx = Instance.new("Sound")
	sfx.Parent = hrp
	sfx.Name = "Electricity"
	sfx.SoundId = "rbxassetid://2710893244"
	sfx.PlaybackSpeed = 2
	sfx.Volume = 1.15
	sfx:Play()
	Debris:AddItem(sfx, 1.512)

	for _, part in pairs(char:GetChildren()) do
		if part.Name == "Right Arm" or part.Name == "Left Arm" then
			local pticle = script:WaitForChild("Electric"):Clone()
			pticle.Enabled = true
			pticle.Parent = part
			task.delay(0.7, function()
				pticle.Enabled = false
			end)
			Debris:AddItem(pticle, 1)
		end
	end	
end

--// SERVER INIT //--
function M1:OnConstructServer()
	self.MutualExclusives = Globals.GeneralMutualExclusives()
	self.CheckOthersActive = true
	self.CheckedByOthers = true
	self.CheckClientState = true

	self:SetMetadata({
		Combo = 1,
		LastTick = 0,
		--Air = false,
		--SpaceHeld = false //For future implementation (uppercut and downslam anims)
	})

	-- Load animations for NPCs
	if not self.Player then
		self.ServerAnimationTracks = {}
		local char = self.Character.Instance
		local hum = char:WaitForChild("Humanoid")
		local animator = hum:WaitForChild("Animator")
		local m1Anims = RS.Assets.Animations:FindFirstChild("M1Anims")

		for i = 1, m1Config.MaxCombo do
			local anim = m1Anims:FindFirstChild(tostring(i))
			if anim and animator then
				self.ServerAnimationTracks[i] = animator:LoadAnimation(anim)
			end
		end
	end
end

--// CLIENT INIT //--
function M1:OnConstructClient()
	local char = self.Character.Instance
	local hrp = char.HumanoidRootPart
	local hum = char:WaitForChild("Humanoid")
	local animator = hum:WaitForChild("Animator")
	local plr = self.Player

	self.AnimationTracks = {}
	self.playerJanitor = Janitor.new()
	self.charJanitor = Janitor.new()

	local function LoadAnimations()
		-- Stop existing tracks
		for _, track in pairs(self.AnimationTracks) do
			if track.IsPlaying then
				track:Stop()
			end
		end
		self.AnimationTracks = {}

		-- Load new animations
		local m1Anims = RS.Assets.Animations:WaitForChild(getAnimationFolder(plr, char))

		for i = 1, m1Config.MaxCombo do
			local anim = m1Anims:WaitForChild(tostring(i))
			if anim and animator then
				self.AnimationTracks[i] = animator:LoadAnimation(anim)
			end
		end
	end

	LoadAnimations()
	
	--Change animations if player's fist type changes (char in case of NPCs)
	if plr then
		self.playerJanitor:Add(plr:GetAttributeChangedSignal("TrainedFists"):Connect(function()
			LoadAnimations()
		end))
	else
		self.charJanitor:Add(char:GetAttributeChangedSignal("TrainedFists"):Connect(function()
			LoadAnimations()
		end))
	end

	-- Play animations on metadata change.
	self.MetadataChanged:Connect(function(newMeta, oldMeta)
		if not oldMeta or newMeta.LastTick == oldMeta.LastTick then
			return
		end
		
		-- Client starts after server finishes running. Metadata sync necessary 
		local comboToPlay = newMeta.Combo - 1
		if comboToPlay == 0 then 
			comboToPlay = m1Config.MaxCombo 
		end 
		
		-- Client side animation play
		local track = self.AnimationTracks[comboToPlay]
		if track then
			track:Play()
		end
		
		-- Apply previous thunder punch VFX if applicable to character
		if hasAttribute(plr, char, "ThunderFists") then applyThunderPunch(char,hrp) end
	end)
	
	-- Cleanup on player leaving to avoid memory leaks (Unsure if WCS already handles cleanup on non-native connections)
	self.playerJanitor:Add(game.Players.PlayerRemoving:Connect(function(player)
		if player == self.Player then
			self.playerJanitor:Cleanup()
		end
	end))
	
	-- Cleanup on player/NPC death to avoid memory leaks (Unsure if WCS already handles cleanup on non-native connections)
	self.charJanitor:Add(self.Player.CharacterRemoving:Connect(function(character)
		if character == char then
			self.charJanitor:Cleanup()
		end
	end))
	
	-- Cleanup on destroy
	self.Destroyed:Connect(function()
		self.playerJanitor:Cleanup()
		self.charJanitor:Cleanup()
		self.playerJanitor:Destroy()
		self.charJanitor:Destroy()
	end)
end


--// SERVER START //--
function M1:OnStartServer(air, spaceHeld)
	--Apply statuses to make sure they can't movestack/run while attacking
	local atk1 = Attacking.new(self.Character)
	atk1:Start(m1Config.Cooldown)
	local noJumper = noJump.new(self.Character)
	noJumper:Start(0.75)
	
	-- Normal character checks
	local char = self.Character.Instance
	local plr = self.Player
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChildOfClass("Humanoid")

	if not (hrp and hum and hum.Health > 0) then return end
	
	-- Initialize metadata (read-only and cannot be modified without setmetadata())
	local meta = self:GetMetadata()
	local comboCount = meta.Combo
	local lastTick = meta.LastTick

	-- Reset combo if timeout exceeded
	if tick() - lastTick > m1Config.ComboTimeout then
		comboCount = 1
	end

	-- Play animation for NPCs
	if not self.Player and self.ServerAnimationTracks then
		local track = self.ServerAnimationTracks[comboCount]
		if track then
			track:Play()
		end
	end
	
	--Boolean for last m1 of chain
	local finalHit = (comboCount == m1Config.MaxCombo)
	
	-- SERVER HIT DETECTION AND DAMAGE LOGIC
	HitboxPacket.OnServerEvent:Once(function(hit, targetHum)
		local victimChar = WCS.Character.GetCharacterFromInstance(targetHum.Parent)
		if not victimChar then return end

		if not self.TargetLastHit then
			self.TargetLastHit = {}
		end
		local now = tick()
		
		-- Anticheat for multiple strikes on same target through same hitbox
		if self.TargetLastHit[hit] and (now - self.TargetLastHit[hit]) < 0.15 then return end
		
		self.TargetLastHit[hit] = now
		
		-- Magnitude check to make sure hitbox packet wasn't fired from an abornmally large distance
		if targetHum ~= self.Character.Instance and targetHum.Parent:FindFirstChild("HumanoidRootPart") then
			local magpos = hrp.Position
			if (magpos-targetHum.Parent.HumanoidRootPart.Position).magnitude > 20 then
				return
			end
		end
		
		-- Sanity check
		if targetHum and targetHum.Health > 0 then
			
			--Damage container and container metadata
			local dmgContainer = self:CreateDamageContainer(5)
			dmgContainer.Ragdoll = finalHit
			dmgContainer.Guardbreak = finalHit
			dmgContainer.Knockback = finalHit
			
			-- Last m1 chain variants (uppercut if grounded and holding space, downslam if used midair)
			if finalHit then
				if air then dmgContainer.Knockback = false dmgContainer.Downslam = true end
				if spaceHeld and not air then dmgContainer.Knockback = false dmgContainer.Knockup = true end
			end
			print("Reached ")
			--Fires WCS DamageTaken Event on target character
			victimChar:TakeDamage(dmgContainer)
		end
	end)
	
	-- Update combo count and apply cooldown
	if finalHit then
		self:ApplyCooldown(m1Config.FinalComboEndlag)
		local stunEffect = AtkStun.new(self.Character)
		stunEffect:Start(m1Config.FinalComboEndlag)
		comboCount = 1
	else
		self:ApplyCooldown(m1Config.Cooldown)
		comboCount += 1
	end

	-- Update metadata
	self:SetMetadata({
		Combo = comboCount,
		LastTick = tick(),
	})
end

--// CLIENT START //--
function M1:OnStartClient(air, spaceHeld)
	local char = self.Character.Instance
	local plr = self.Player
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChildOfClass("Humanoid")
	local meta = self:GetMetadata()

	if not (hrp and hum and hum.Health > 0) then return end
	
	-- Client-side hitboxes (Delay based on windup)
	task.delay(m1Config.Windup, function()
		if not self.Character or not self.Character.Instance then return end
		-- Hitbox creation (MuchachoHitbox open source hitbox library)
		
		--Client starts after server finishes running. Metadata sync necessary
		local isFinalHit = (meta.Combo - 1 == 0)
		
		--Excluding self from hitbox detection
		local ovParams = OverlapParams.new()
		ovParams.FilterType = Enum.RaycastFilterType.Exclude
		ovParams.FilterDescendantsInstances = {char}
		
		-- https://github.com/CatSushi/MuchachoHitbox/wiki for API and documentation
		local hitbox = MuchachoHitbox.CreateHitbox()
		hitbox.Shape = Enum.PartType.Block
		hitbox.CFrame = hrp
		hitbox.DetectionMode = "Default"
		hitbox.Offset = m1Config.HitboxOffset
		hitbox.Size = (isFinalHit and Vector3.new(6, 6, 7)) or m1Config.HitboxSize
		hitbox.VelocityPrediction = true
		hitbox.VelocityPredictionTime = 0.05
		hitbox.OverlapParams = ovParams

		local hitTargets = {}
		
		-- Hitbox detection (no need to cleanup as MuchachoHitbox handles its own garbage collection)
		hitbox.Touched:Connect(function(hit, targetHum)
			if targetHum.Health <= 0 then
				return
			end
			
			--Initial sanity check to ensure each target only gets hit by hitbox once
			if hitTargets[targetHum] then
				return
			end
			hitTargets[targetHum] = true
			
			--Send hit metadata to server
			HitboxPacket:Fire(targetHum)
		end)
		
		--Create the configured hitbox
		hitbox:Start()
		
		--Cleanup (MuchachoHitbox handles Janitor operations and connection cleanup)
		task.delay(0.15, function()
			if hitbox then
				hitbox:Stop()
			end
		end)
	end)
end

return M1
