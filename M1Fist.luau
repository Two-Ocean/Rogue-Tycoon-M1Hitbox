--// DEPENDENCIES //--
local WCS = require(game.ReplicatedStorage.wcs)
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

--// WCS STATUS EFFECTS //--
-- These status effects block move stacking and jumping during the attack window
local Attacking : WCS.StatusEffect = _G.StatusEffects.Attacking
local NoJump : WCS.StatusEffect = _G.StatusEffects.NoJump
local AtkStun : WCS.StatusEffect = _G.StatusEffects.AttackingStun

--// SHARED SERVICES //--
local Globals = _G.Shared.Globals
local MuchachoHitbox = _G.Shared.MuchachoHitbox
local Packet = require(RS.Services.Packet)

--// LOCAL MODULES //--
local Config : {string} = require(RS.Combat.Modules.Config)
local Janitor = require(RS.Services.Shared.Packages.Janitor)

--// CONFIG //--
-- Combo tuning values (cooldown, windup, hitbox size, etc.)
local m1Config = Config.M1Fist.M1

--// HIT DETECTION PACKET //--
-- Fires from client to server when the client-side hitbox detects a valid target humanoid
local HitboxPacket = Packet("M1Hit", Packet.Instance)

--// TYPE DEFINITIONS //--

-- Damage container produced by WCS; fields beyond base damage and source (source is set to self.Character by default) are optional flags
export type DamageContainer = {
	Damage : number,
	Ragdoll : boolean?,
	Guardbreak : boolean?,
	Knockback : boolean?,
	Knockup : boolean?,
	Downslam : boolean?,
}

export type ComboMetadata = {
	Combo : number,
	LastTick : number,  -- os.clock() timestamp of last used attack for timeout reset
}

-- Convenience bundle passed to the final-hit variant resolver
type FinalHitParams = {
	air : boolean,
	spaceHeld : boolean,
	container : DamageContainer,
}

--// CONSTANTS //--
local thunderColor = Color3.fromRGB(26, 194, 255)
local thunderSFXID = "rbxassetid://2710893244"
local thunderTweenIn = TweenInfo.new(0.2)
local thunderTweenOut = TweenInfo.new(0.2)
local R6armNames = { ["Right Arm"] = true, ["Left Arm"] = true }
-- How close (studs) a target must be for a server hit to be accepted
local maxHitDistance = 20
-- Minimum seconds between two accepted hits on the same target (anti-multifire)
local hitCooldown = 0.05

--// REGISTER SKILL //--
local M1 = WCS.RegisterSkill(script.Name)

-- ─────────────────────────────────────────────────────────────────────────────
--  HELPER FUNCTIONS
-- ─────────────────────────────────────────────────────────────────────────────

-- Returns true if the player (or character for NPCs) carries a truthy value for `attr`.
-- Characters without a player (NPCs) will only check the character instance.
local function hasAttribute(plr: Player?, char: Model, attr: string): boolean
	return (plr ~= nil and plr:GetAttribute(attr) == true)
		or char:GetAttribute(attr) == true
end

-- Selects which animation folder to use based on fist training state.
local function getAnimFolder(plr: Player?, char: Model): string
	return hasAttribute(plr, char, "TrainedFists") and "TrainedM1Anims" or "M1Anims"
end

-- Applies the Thunder Fists visual and audio effect to the character. 
-- This involves a tweened light for the electric flash, an electric sound and particle emitters cloned on both arms briefly.
local function applyThunderPunch(char: Model, hrp: BasePart)
	-- PointLight flash
	local pl = Instance.new("PointLight")
	pl.Color = thunderColor
	pl.Brightness = 0
	pl.Range = 0
	pl.Parent = hrp

	TweenService:Create(pl, thunderTweenIn, { Range = 10, Brightness = 0.75 }):Play()
	task.delay(0.2, function()
		TweenService:Create(pl, thunderTweenOut, { Range = 0, Brightness = 0 }):Play()
	end)

	-- Electricity sound (pitched up to sound more crackling/urgent)
	local sfx = Instance.new("Sound")
	sfx.SoundId = thunderSFXID
	sfx.PlaybackSpeed = 2
	sfx.Volume = 1.15
	sfx.Parent = hrp
	sfx:Play()
	Debris:AddItem(sfx, 1.5)

	-- Particle emitters on both arms
	for _, part in ipairs(char:GetChildren()) do
		if not R6armNames[part.Name] then continue end

		local emitter = script:WaitForChild("Electric"):Clone()
		emitter.Enabled = true
		emitter.Parent = part

		-- Disable emission after 0.7 s; particle lifetime keeps them visible briefly after
		task.delay(0.7, function() emitter.Enabled = false end)
		Debris:AddItem(emitter, 1)
	end
end

-- Checks final hit parameters and sets the container c based on the attacker's jump and space hold state
local function resolveFinalHitFlags(params: FinalHitParams)
	local c = params.container

	if params.air then
		c.Knockback = false
		c.Downslam  = true
	elseif params.spaceHeld then
		c.Knockback = false
		c.Knockup   = true
	end
	-- Ragdoll and Guardbreak remain true from the caller for all final-hit variants
end

-- Validates server-side hit from client-created hitbox. Returns false (and silently rejects) if invalid.
local function isValidHit(self : any, hit : Instance, targetHum : Humanoid, attackerHRP: BasePart): boolean
	-- Target must belong to a valid WCS character
	if not WCS.Character.GetCharacterFromInstance(targetHum.Parent) then
		return false
	end

	-- Initialise last-hit cache on first use
	if not self.TargetLastHit then
		self.TargetLastHit = {}
	end

	local now = os.clock()

	-- Reject if this target was struck too recently (prevents double-registration)
	if self.TargetLastHit[hit] and (now - self.TargetLastHit[hit]) < hitCooldown then
		return false
	end
	self.TargetLastHit[hit] = now

	-- Magnitude check: reject hits registered from an implausible distance
	local targetHRP = targetHum.Parent:FindFirstChild("HumanoidRootPart") :: BasePart?
	if targetHRP and (attackerHRP.Position - targetHRP.Position).Magnitude > maxHitDistance then
		return false
	end

	return targetHum.Health > 0
end

----------------------------------------------------------------------------------------------------------------------
-- Better be fucking specific and dm me personally if this shit gets rejected too

-- OnConstructServer runs once when the skill object is first built on character added through a Skill.new(args...) 
-- Metadata, mutual exclusives (conflicting skills/statuses) and pre loads are handled here.
function M1:OnConstructServer()
	-- Prevent this skill from firing while other general-movement skills are active
	self.MutualExclusives  = Globals.GeneralMutualExclusives()
	self.CheckOthersActive = true
	self.CheckedByOthers   = true
	self.CheckClientState  = true

	-- Initial combo state; LastTick = 0 ensures the first swing always starts at combo 1
	self:SetMetadata({ Combo = 1, LastTick = 0 } :: ComboMetadata)

	-- NPC-only: load server-side animation tracks (players animate on the client)
	if self.Player then return end

	self.ServerAnimationTracks = {}
	local char     = self.Character.Instance
	local animator = char:WaitForChild("Humanoid"):WaitForChild("Animator")
	local anims    = RS.Assets.Animations:FindFirstChild("M1Anims")

	for i = 1, m1Config.MaxCombo do
		local anim = anims and anims:FindFirstChild(tostring(i))
		if anim then
			self.ServerAnimationTracks[i] = animator:LoadAnimation(anim)
		end
	end
end

----------------------------------------------------------------------------------------------------------------------

-- OnConstructClient follows up after OnConstructServer setting up the skill on the client. 
-- Here, animations are loaded, listeners are set up for attribute changes and janitor cleanups are setup for all client-related events
function M1:OnConstructClient()
	local char = self.Character.Instance
	local plr = self.Player
	local hrp = char.HumanoidRootPart
	local animator = char:WaitForChild("Humanoid"):WaitForChild("Animator")

	self.AnimationTracks = {}
	self.playerJanitor = Janitor.new()
	self.charJanitor = Janitor.new()

	-- Loads and caches all combo animation tracks from the correct folder.
	-- Called on construction and whenever the TrainedFists attribute changes.
	local function loadAnimations()
		for _, track in ipairs(self.AnimationTracks) do
			if track.IsPlaying then track:Stop() end
		end
		self.AnimationTracks = {}

		local folder = RS.Assets.Animations:WaitForChild(getAnimFolder(plr, char))
		for i = 1, m1Config.MaxCombo do
			local anim = folder:WaitForChild(tostring(i))
			self.AnimationTracks[i] = animator:LoadAnimation(anim)
		end
	end

	loadAnimations()

	-- Hot-swap animations when the player's fist type changes mid-session
	local attrSignal = plr
		and plr:GetAttributeChangedSignal("TrainedFists")
		or  char:GetAttributeChangedSignal("TrainedFists")
	local targetJanitor = plr and self.playerJanitor or self.charJanitor
	targetJanitor:Add(attrSignal:Connect(loadAnimations))
	
	-- Metadata change fires first to server and then to client. On client's metadata updating we play the animation of the combo metadata before the server's update.
	
	self.MetadataChanged:Connect(function(newMeta: ComboMetadata, oldMeta: ComboMetadata?)
		-- Ignore the initial replication or duplicate syncs with no tick advancement
		if not oldMeta or newMeta.LastTick == oldMeta.LastTick then return end

		-- Server changed Combo Metadata before client runs, so the played index is one behind
		local comboToPlay = newMeta.Combo - 1
		if comboToPlay < 1 then comboToPlay = m1Config.MaxCombo end

		local track = self.AnimationTracks[comboToPlay]
		if track then track:Play() end

		-- Thunder Fists VFX plays alongside the animation on each swing
		if hasAttribute(plr, char, "ThunderFists") then
			applyThunderPunch(char, hrp)
		end
	end)

	-- ── Cleanup wiring ──────────────────────────────────────────────────────

	-- Clean up player connections when the player leaves
	self.playerJanitor:Add(game.Players.PlayerRemoving:Connect(function(leavingPlr)
		if leavingPlr ~= plr then return end
		self.playerJanitor:Cleanup()
	end))

	-- Clean up character connections on character removal (respawn / death)
	self.charJanitor:Add(self.Character.CharacterDestroyed:Connect(function(removedChar)
		if removedChar ~= char then return end
		self.charJanitor:Cleanup()
	end))

	-- Final cleanup when WCS destroys this skill instance entirely
	self.Destroyed:Connect(function()
		self.playerJanitor:Cleanup()
		self.charJanitor:Cleanup()
		self.playerJanitor:Destroy()
		self.charJanitor:Destroy()
	end)
end

----------------------------------------------------------------------------------------------------------------------

-- When the skill is used, OnStartServer runs and then OnStartClient runs afterrwards. 
-- Here, server-authoritative tasks like applying status effects, changing metadata, NPC handling, skill cooldown and weird packet behavior are monitored. 
function M1:OnStartServer(air: boolean, spaceHeld: boolean)
	-- Lock out movement-affecting skills and jumping for the attack duration
	Attacking.new(self.Character):Start(m1Config.Cooldown)
	NoJump.new(self.Character):Start(0.75)

	local char = self.Character.Instance
	local plr = self.Player
	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = char:FindFirstChildOfClass("Humanoid")   :: Humanoid?

	-- Early exit: character is missing critical parts or is already dead
	if not hrp or not hum or hum.Health <= 0 then return end

	local meta : ComboMetadata = self:GetMetadata()
	local comboCount : number = meta.Combo

	-- Reset to the start of the chain if the player waited too long between swings
	if os.clock() - meta.LastTick > m1Config.ComboTimeout then
		comboCount = 1
	end

	-- NPCs animate on the server since they have no owning client
	if not plr and self.ServerAnimationTracks then
		local track = self.ServerAnimationTracks[comboCount]
		if track then track:Play() end
	end

	local isFinalHit = comboCount == m1Config.MaxCombo

	-- One-off listener created everytime the skill is used: the client fires this packet once per hitbox contact. 
	HitboxPacket.OnServerEvent:Once(function(hit: Instance, targetHum: Humanoid)
		if not isValidHit(self, hit, targetHum, hrp) then return end

		local victimChar = WCS.Character.GetCharacterFromInstance(targetHum.Parent)

		-- Build base damage container (5 damage, final-hit flags pre-set)
		local dmgContainer: DamageContainer = self:CreateDamageContainer(5)
		dmgContainer.Ragdoll = isFinalHit
		dmgContainer.Guardbreak = isFinalHit
		dmgContainer.Knockback = isFinalHit

		-- Resolve knockback variant for the final hit only
		if isFinalHit then
			resolveFinalHitFlags({ air = air, spaceHeld = spaceHeld, container = dmgContainer })
		end

		victimChar:TakeDamage(dmgContainer)
	end)

	-- Apply cooldown and advance or reset the combo counter
	if isFinalHit then
		self:ApplyCooldown(m1Config.FinalComboEndlag)
		AtkStun.new(self.Character):Start(m1Config.FinalComboEndlag)
		comboCount = 1
	else
		self:ApplyCooldown(m1Config.Cooldown)
		comboCount += 1
	end

	self:SetMetadata({ Combo = comboCount, LastTick = os.clock() } :: ComboMetadata)
end

----------------------------------------------------------------------------------------------------------------------

-- OnStartClient runs after OnStartServer and handles client-side hitbox creation after configured windup delay. 
-- On final combo hit, the hitbox is slightly larger as it knocks back and is more focused on finishing combos or guardbreaking turtling opponents.
-- Each valid contact fires a HitboxPacket to the server for validation.
function M1:OnStartClient(air: boolean, spaceHeld: boolean)
	local char = self.Character.Instance
	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = char:FindFirstChildOfClass("Humanoid")   :: Humanoid?
	local meta : ComboMetadata = self:GetMetadata()

	if not hrp or not hum or hum.Health <= 0 then return end

	-- Determine whether this swing is the final hit BEFORE the server increments Combo
	-- (client metadata lags one frame behind; Combo gets to set to 1 on MaxCombo so Combo - 1 == 0 means we are on MaxCombo. Think of it as starting from 2, going to 4, and ending at 0.)
	local isFinalHit = (meta.Combo - 1 == 0)

	-- Delay hitbox creation by the windup duration so it aligns with the animation contact frame
	task.delay(m1Config.Windup, function()
		if not self.Character or not self.Character.Instance then return end

		-- Exclude the attacker's own character from hitbox detection
		local ovParams = OverlapParams.new()
		ovParams.FilterType                 = Enum.RaycastFilterType.Exclude
		ovParams.FilterDescendantsInstances = { char }

		-- Build the hitbox; final hit uses a wider/deeper box for the launcher/slam
		local hitbox = MuchachoHitbox.CreateHitbox()
		hitbox.Shape = Enum.PartType.Block
		hitbox.CFrame = hrp
		hitbox.DetectionMode = "Default"
		hitbox.Offset = m1Config.HitboxOffset
		hitbox.Size = isFinalHit and Vector3.new(6, 6, 7) or m1Config.HitboxSize
		hitbox.VelocityPrediction = true
		hitbox.VelocityPredictionTime = 0.05
		hitbox.OverlapParams = ovParams

		-- Track which humanoids this hitbox has already registered to prevent double-hits
		local hitTargets: { [Humanoid]: boolean } = {}

		hitbox.Touched:Connect(function(hit: Instance, targetHum: Humanoid)
			if targetHum.Health <= 0  then return end
			if hitTargets[targetHum]  then return end

			hitTargets[targetHum] = true
			-- Notify the server; authoritative damage is applied in OnStartServer
			HitboxPacket:Fire(targetHum)
		end)

		hitbox:Start()

		-- Stop detection after the active window; MuchachoHitbox cleans up internally
		task.delay(0.15, function()
			if hitbox then hitbox:Stop() end
		end)
	end)
end

return M1
