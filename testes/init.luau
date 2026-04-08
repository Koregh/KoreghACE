local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestEZ = require(ReplicatedStorage.TestEZ) -- TestEZ is a Roblox testing framework (like a “JUnit” or “Jest” in life)
TestEZ.TestBootstrap:run({ ReplicatedStorage.Tests })
