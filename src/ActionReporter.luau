--!strict
--!optimize 2

local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- CryptoLib must be in ReplicatedStorage.Shared so both sides share it.
-- Adjust path to match your instance tree.
local CryptoLib = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CryptoLib"))

local function waitEvent(name: string): RemoteEvent
	local r = ReplicatedStorage:WaitForChild(name, 10)
	assert(r, "[AC] Remote not found: " .. name)
	return r :: RemoteEvent
end
local function waitFunc(name: string): RemoteFunction
	local r = ReplicatedStorage:WaitForChild(name, 10)
	assert(r, "[AC] RemoteFunction not found: " .. name)
	return r :: RemoteFunction
end

local HandshakeFunc : RemoteFunction = waitFunc("AC_Handshake")
local FpsEvent      : RemoteEvent    = waitEvent("AC_FPS")
local ActionEvent   : RemoteEvent    = waitEvent("AC_Action")
local StimulusEvent : RemoteEvent    = waitEvent("AC_Stimulus")
local HitEvent      : RemoteEvent    = waitEvent("AC_Hit")

local _key   : { number } = {}
local _nonce : number     = 0
local _ready : boolean    = false

local function doHandshake(): ()
	local fps : number = math.floor(1 / RunService.RenderStepped:Wait())
	fps = math.clamp(fps, 5, 240)

	local keyBytes : unknown = HandshakeFunc:InvokeServer(fps)
	if type(keyBytes) ~= "table" or #(keyBytes :: { any }) ~= 16 then
		warn("[AC] Handshake failed — no key received")
		return
	end
	_key   = keyBytes :: { number }
	_nonce = 0
	_ready = true
end

-- Handshake on a background thread so it does not block the client
task.spawn(doHandshake)

local function encode(bytes: { number }): { nonce: number, cs: number, data: { number } }?
	if not _ready then return nil end
	_nonce += 1
	return CryptoLib.encode(bytes, _key, _nonce)
end

local function fireEncoded(remote: RemoteEvent, bytes: { number }): ()
	local pkt = encode(bytes)
	if pkt then remote:FireServer(pkt) end
end

local ActionId = {
	PRIMARY   = 0,
	SECONDARY = 1,
	JUMP      = 2,
	SPRINT    = 3,
	ABILITY_1 = 4,
	ABILITY_2 = 5,
	RELOAD    = 6,
	ADS       = 7,
	MELEE     = 8,
}

local _lastFire : { [number]: number } = {}
local DEBOUNCE  : number = 0.016

local function fire(actionId: number): ()
	local now  : number = os.clock()
	if (now - (_lastFire[actionId] or 0)) < DEBOUNCE then return end
	_lastFire[actionId] = now
	-- Payload: 1 byte = actionId
	fireEncoded(ActionEvent, { actionId })
end

UserInputService.InputBegan:Connect(function(input: InputObject, gpe: boolean)
	if gpe then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then fire(ActionId.PRIMARY)
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then fire(ActionId.SECONDARY)
	elseif input.KeyCode == Enum.KeyCode.Space  then fire(ActionId.JUMP)
	elseif input.KeyCode == Enum.KeyCode.R      then fire(ActionId.RELOAD)
	end
end)

-- Send current FPS to server once per minute (unencrypted — not
-- sensitive, and encryption requires ready state).
local _fpsTick : number = 0.0
RunService.Heartbeat:Connect(function(dt: number)
	_fpsTick += dt
	if _fpsTick < 60.0 then return end
	_fpsTick = 0.0
	local fps : number = math.clamp(math.floor(1 / dt), 5, 240)
	FpsEvent:FireServer(fps)
end)

local ActionReporter = {}
ActionReporter.ActionId = ActionId

function ActionReporter.fireAction(actionId: number): ()
	fire(math.clamp(actionId, 0, 31))
end

function ActionReporter.onStimulus(): ()
	-- Payload: 1 sentinel byte
	fireEncoded(StimulusEvent, { 0x01 })
end

--[[
	Submit a hit request.
	Position is encoded as integer studs with +32768 offset
	(range -32768..32767 studs — sufficient for any Roblox map).
	Upgrade to f32 packing if sub-stud precision matters.
]]
function ActionReporter.submitHit(
	victimId    : number,
	clientPos   : Vector3,
	weaponRange : number,
	damage      : number,
	isHeadshot  : boolean
): ()
	-- Pack victim ID (u32)
	local vBytes = CryptoLib.packU32(victimId)
	-- Pack position (integer studs, offset-encoded)
	local xBytes = CryptoLib.packU32(math.clamp(math.round(clientPos.X) + 32768, 0, 65535))
	local yBytes = CryptoLib.packU32(math.clamp(math.round(clientPos.Y) + 32768, 0, 65535))
	local zBytes = CryptoLib.packU32(math.clamp(math.round(clientPos.Z) + 32768, 0, 65535))
	local rBytes = CryptoLib.packU32(math.clamp(math.round(weaponRange), 0, 65535))
	local dBytes = CryptoLib.packU32(math.clamp(math.round(damage),      0, 65535))
	local flags  : number = if isHeadshot then 1 else 0

	-- Assemble 25-byte payload
	local payload : { number } = {
		vBytes[1], vBytes[2], vBytes[3], vBytes[4],
		xBytes[1], xBytes[2], xBytes[3], xBytes[4],
		yBytes[1], yBytes[2], yBytes[3], yBytes[4],
		zBytes[1], zBytes[2], zBytes[3], zBytes[4],
		rBytes[1], rBytes[2], rBytes[3], rBytes[4],
		dBytes[1], dBytes[2], dBytes[3], dBytes[4],
		flags,
	}

	fireEncoded(HitEvent, payload)
end

return ActionReporter
