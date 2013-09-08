--[[
The MIT License (MIT)

Copyright (c) 2013 Alex Szpakowski

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
]]


assert(love, "LOVE (https://love2d.org/) is required.")
assert(love._version_major > 0 or love._version_minor >= 9, "LOVE version 0.9.0+ is required.")


local type, pcall, unpack = type, pcall, unpack
local love = love

-- In the absence of a system-provided thread ID, we can just use a value which
-- is unique to this Lua state.
local thread_id = tostring(love):gsub("table: ", "")

local Mutex = {}
Mutex.__index = Mutex

local function new_mutex(other)
	local m = {}
	
	if type(other) == "string" then
		-- Named mutex.
		m.name = other
		
		-- The name channel should contain the channels needed to use the mutex.
		local name_channel = love.thread.getChannel("__mutex_"..m.name)
		
		if name_channel:getCount() == 0 then
			local new_owner = love.thread.newChannel()
			local new_channel = love.thread.newChannel()
			
			-- Init the main channel before pushing it to the name channel,
			-- to avoid race conditions.
			new_channel:push(true)
			name_channel:push({new_owner, new_channel})
		end
		
		local channels = name_channel:peek()
		if channels then
			m.owner = channels[1]
			m.channel = channels[2]
		end
	elseif type(other) == "table" and other.channel then
		-- Inherit from an existing mutex.
		m.owner = other.owner
		m.channel = other.channel
		m.name = other.name
	elseif other == nil then
		-- Create a completely new mutex.
		-- m.owner keeps track of the thread which currently owns the mutex.
		m.owner = love.thread.newChannel()
		
		-- the mutex is unlocked if a shared resource in m.channel exists.
		m.channel = love.thread.newChannel()
		m.channel:push(true)
	end
	
	if type(m.channel) ~= "userdata" or not getmetatable(m.channel).typeOf
	or not m.channel:typeOf("Channel") then
		error("Could not create mutex.", 2)
	end
	
	-- Counter required for locking multiple times in the same thread.
	m.recursive = 0
	
	return setmetatable(m, Mutex)
end

function Mutex:lock()
	if self.owner:peek() == thread_id then
		-- This thread has already locked this mutex, so just increment the
		-- counter and report success.
		self.recursive = self.recursive + 1
		return true
	elseif self.channel:demand() ~= nil then
		-- Only update the owner thread id for the mutex once we've acquired
		-- the lock.
		self.owner:clear()
		self.owner:push(thread_id)
		self.recursive = 0
		return true
	end
	return false
end

function Mutex:tryLock()
	if self.owner:peek() == thread_id then
		-- This thread has already locked this mutex, so just increment the
		-- counter and report success.
		self.recursive = self.recursive + 1
		return true
	elseif self.channel:pop() ~= nil then
		-- Only acquire the lock if nothing else has it already, and only
		-- update the owner thread id for the mutex if we acquired the lock.
		self.owner:clear()
		self.owner:push(thread_id)
		self.recursive = 0
		return true
	end
	return false
end

function Mutex:unlock()
	-- We can only unlock the mutex if we own it.
	if self.owner:peek() ~= thread_id then
		return false
	end
	
	if self.recursive > 0 then
		-- This thread has locked the mutex multiple times, so just decrement
		-- the counter and report success.
		self.recursive = self.recursive - 1
	else
		-- Clear the owner thread ID *before* unlocking.
		self.owner:clear()
		self.channel:push(true)
	end
	return true
end

function Mutex:lockFunction(func, ...)
	self:lock()
	local rets = {pcall(func, ...)}
	self:unlock()
	
	if rets[1] then
		-- return ret1, ret2, ..
		return unpack(rets, 2)
	else
		return error(rets[2], 2)
	end
end

function Mutex:tryLockFunction(func, ...)
	if not self:tryLock() then
		return false
	end
	local rets = {pcall(func, ...)}
	self:unlock()
	
	if rets[1] then
		-- return true, ret1, ret2, ..
		return unpack(rets)
	else
		-- return ret1, ret2, ..
		return error(rets[2], 2)
	end
end

function Mutex:getName()
	-- name only exists for named mutexes.
	return self.name
end

function Mutex:__eq(other)
	return self.channel == other.channel
end

return setmetatable({new=new_mutex}, {__call=function(_, ...) return new_mutex(...) end})
