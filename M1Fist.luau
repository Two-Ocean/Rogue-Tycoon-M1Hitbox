local WCS = require(game.ReplicatedStorage.wcs)

--// WCS STATUSES //--
local Attacking = _G.StatusEffects.Attacking
local noJump = _G.StatusEffects.NoJump
local AtkStun = _G.StatusEffects.AttackingStun
--// SERVICES //--
local RS : ReplicatedStorage = game:GetService("ReplicatedStorage")

--// UTIL MODULES //--
local Config :ModuleScript = require(RS.Combat.Modules.Config)
local Globals :ModuleScript = _G.SharedServices.Globals
local MuchachoHitbox :ModuleScript = _G.SharedServices.MuchachoHitbox
local Packet = _G.SharedServices.Packet
local m1Config = Config.M1Fist.M1

local HitboxPacket = Packet("M1Hit", Packet.Instance)

local M1 = WCS.RegisterSkill(script.Name)

local function getAnimationFolder(plr, char)
	return "M1Anims"
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
	local hum = char:WaitForChild("Humanoid")
	local animator = hum:WaitForChild("Animator")
	local plr = self.Player

	self.AnimationTracks = {}

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

	-- Play animations on metadata change
	self.MetadataChanged:Connect(function(newMeta, oldMeta)
		if not oldMeta or newMeta.LastTick == oldMeta.LastTick then
			return
		end

		local comboToPlay = newMeta.Combo - 1
		if comboToPlay == 0 then 
			comboToPlay = m1Config.MaxCombo 
		end 

		local track = self.AnimationTracks[comboToPlay]
		if track then
			track:Play()
		end
	end)
end


--// SERVER START //--
function M1:OnStartServer(air, spaceHeld)
	local atk1 = Attacking.new(self.Character)
	atk1:Start(m1Config.Cooldown)
	local noJumper = noJump.new(self.Character)
	noJumper:Start(0.75)

	local char = self.Character.Instance
	local plr = self.Player
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChildOfClass("Humanoid")

	if not (hrp and hum and hum.Health > 0) then return end

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
			
			if finalHit then
				if air then dmgContainer.Knockback = false dmgContainer.Downslam = true end
				if spaceHeld then dmgContainer.Knockback = false dmgContainer.Knockup = true end
			end
			print("Reached ")
			--Fires WCS DamageTaken Event on target character
			victimChar:TakeDamage(dmgContainer)
		end
	end)
	
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
	
	task.delay(m1Config.Windup, function()
		if not self.Character or not self.Character.Instance then return end
		-- Hitbox creation (MuchachoHitbox OSS library)

		local isFinalHit = (meta.Combo - 1 == 0)
 
		local ovParams = OverlapParams.new()
		ovParams.FilterType = Enum.RaycastFilterType.Exclude
		ovParams.FilterDescendantsInstances = {char}

		local hitbox = MuchachoHitbox.CreateHitbox()
		hitbox.Shape = Enum.PartType.Block
		hitbox.CFrame = hrp
		hitbox.DetectionMode = "Default"
		hitbox.Offset = m1Config.HitboxOffset
		hitbox.Size = (isFinalHit and Vector3.new(6, 6, 7)) or m1Config.HitboxSize
		print(hitbox.Size)
		hitbox.VelocityPrediction = true
		hitbox.VelocityPredictionTime = 0.05
		hitbox.OverlapParams = ovParams

		local hitTargets = {}
		
		-- Hitbox detection
		hitbox.Touched:Connect(function(hit, targetHum)
			print(hit)
			print(targetHum)
			if targetHum.Health <= 0 then
				return
			end

			if hitTargets[targetHum] then
				return
			end
			hitTargets[targetHum] = true

			HitboxPacket:Fire(targetHum)
		end)

		hitbox:Start()

		task.delay(0.15, function()
			if hitbox then
				hitbox:Stop()
			end
		end)
	end)
end

return M1
