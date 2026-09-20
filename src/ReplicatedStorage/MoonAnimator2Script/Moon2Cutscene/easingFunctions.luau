--[[
	缓动函数模块
	提供各种缓动（Easing）函数，用于动画插值
	来源：moon2 源码
	参考：https://github.com/EmmanuelOga/easing/blob/master/lib/easing.lua
	参考：https://github.com/behollister/blender2.8/blob/blender2.8/source/blender/blenlib/intern/easing.c
]]

local module = {}

-- https://github.com/EmmanuelOga/easing/blob/master/lib/easing.lua and https://github.com/behollister/blender2.8/blob/blender2.8/source/blender/blenlib/intern/easing.c

module.Linear = function(val)
	return val
end

module.Constant = function(val)
	return val == 1 and 1 or 0
end

local function inSine(t, b, c, d)
	return -c * math.cos(t / d * (math.pi / 2)) + c + b
end
local function outSine(t, b, c, d)
	return c * math.sin(t / d * (math.pi / 2)) + b
end
local function inOutSine(t, b, c, d)
	return -c / 2 * (math.cos(math.pi * t / d) - 1) + b
end
local function outInSine(t, b, c, d)
	if t < d / 2 then
		return outSine(t * 2, b, c / 2, d)
	else
		return inSine((t * 2) -d, b + c / 2, c / 2, d)
	end
end

module.SineIn = function(val)
	return inSine(val, 0, 1, 1)
end
module.SineOut = function(val)
	return outSine(val, 0, 1, 1)
end
module.SineInOut = function(val)
	return inOutSine(val, 0, 1, 1)
end
module.SineOutIn = function(val)
	return outInSine(val, 0, 1, 1)
end

local function inQuad(t, b, c, d)
	t = t / d
	return c * math.pow(t, 2) + b
end
local function outQuad(t, b, c, d)
	t = t / d
	return -c * t * (t - 2) + b
end
local function inOutQuad(t, b, c, d)
	t = t / d * 2
	if t < 1 then
		return c / 2 * math.pow(t, 2) + b
	else
		return -c / 2 * ((t - 1) * (t - 3) - 1) + b
	end
end
local function outInQuad(t, b, c, d)
	if t < d / 2 then
		return outQuad(t * 2, b, c / 2, d)
	else
		return inQuad((t * 2) - d, b + c / 2, c / 2, d)
	end
end

module.QuadIn = function(val)
	return inQuad(val, 0, 1, 1)
end
module.QuadOut = function(val)
	return outQuad(val, 0, 1, 1)
end
module.QuadInOut = function(val)
	return inOutQuad(val, 0, 1, 1)
end
module.QuadOutIn = function(val)
	return outInQuad(val, 0, 1, 1)
end

local function inCubic(t, b, c, d)
	t = t / d
	return c * math.pow(t, 3) + b
end
local function outCubic(t, b, c, d)
	t = t / d - 1
	return c * (math.pow(t, 3) + 1) + b
end
local function inOutCubic(t, b, c, d)
	t = t / d * 2
	if t < 1 then
		return c / 2 * t * t * t + b
	else
		t = t - 2
		return c / 2 * (t * t * t + 2) + b
	end
end
local function outInCubic(t, b, c, d)
	if t < d / 2 then
		return outCubic(t * 2, b, c / 2, d)
	else
		return inCubic((t * 2) - d, b + c / 2, c / 2, d)
	end
end

module.CubicIn = function(val)
	return inCubic(val, 0, 1, 1)
end
module.CubicOut = function(val)
	return outCubic(val, 0, 1, 1)
end
module.CubicInOut = function(val)
	return inOutCubic(val, 0, 1, 1)
end
module.CubicOutIn = function(val)
	return outInCubic(val, 0, 1, 1)
end

local function inQuart(t, b, c, d)
	t = t / d
	return c * math.pow(t, 4) + b
end
local function outQuart(t, b, c, d)
	t = t / d - 1
	return -c * (math.pow(t, 4) - 1) + b
end
local function inOutQuart(t, b, c, d)
	t = t / d * 2
	if t < 1 then
		return c / 2 * math.pow(t, 4) + b
	else
		t = t - 2
		return -c / 2 * (math.pow(t, 4) - 2) + b
	end
end
local function outInQuart(t, b, c, d)
	if t < d / 2 then
		return outQuart(t * 2, b, c / 2, d)
	else
		return inQuart((t * 2) - d, b + c / 2, c / 2, d)
	end
end

module.QuartIn = function(val)
	return inQuart(val, 0, 1, 1)
end
module.QuartOut = function(val)
	return outQuart(val, 0, 1, 1)
end
module.QuartInOut = function(val)
	return inOutQuart(val, 0, 1, 1)
end
module.QuartOutIn = function(val)
	return outInQuart(val, 0, 1, 1)
end

local function inQuint(t, b, c, d)
	t = t / d
	return c * math.pow(t, 5) + b
end
local function outQuint(t, b, c, d)
	t = t / d - 1
	return c * (math.pow(t, 5) + 1) + b
end
local function inOutQuint(t, b, c, d)
	t = t / d * 2
	if t < 1 then
		return c / 2 * math.pow(t, 5) + b
	else
		t = t - 2
		return c / 2 * (math.pow(t, 5) + 2) + b
	end
end
local function outInQuint(t, b, c, d)
	if t < d / 2 then
		return outQuint(t * 2, b, c / 2, d)
	else
		return inQuint((t * 2) - d, b + c / 2, c / 2, d)
	end
end

module.QuintIn = function(val)
	return inQuint(val, 0, 1, 1)
end
module.QuintOut = function(val)
	return outQuint(val, 0, 1, 1)
end
module.QuintInOut = function(val)
	return inOutQuint(val, 0, 1, 1)
end
module.QuintOutIn = function(val)
	return outInQuint(val, 0, 1, 1)
end

local function inSextic(t, b, c, d)
	t = t / d
	return c * math.pow(t, 6) + b
end
local function outSextic(t, b, c, d)
	t = t / d - 1
	return -c * (math.pow(t, 6) - 1) + b
end
local function inOutSextic(t, b, c, d)
	t = t / d * 2
	if t < 1 then
		return c / 2 * math.pow(t, 6) + b
	else
		t = t - 2
		return -c / 2 * (math.pow(t, 6) - 2) + b
	end
end
local function outInSextic(t, b, c, d)
	if t < d / 2 then
		return outSextic(t * 2, b, c / 2, d)
	else
		return inSextic((t * 2) - d, b + c / 2, c / 2, d)
	end
end

module.SexticIn = function(val)
	return inSextic(val, 0, 1, 1)
end
module.SexticOut = function(val)
	return outSextic(val, 0, 1, 1)
end
module.SexticInOut = function(val)
	return inOutSextic(val, 0, 1, 1)
end
module.SexticOutIn = function(val)
	return outInSextic(val, 0, 1, 1)
end

local function inExpo(t, b, c, d)
	if t == 0 then
		return b
	else
		return c * math.pow(2, 10 * (t / d - 1)) + b - c * 0.001
	end
end
local function outExpo(t, b, c, d)
	if t == d then
		return b + c
	else
		return c * 1.001 * (-math.pow(2, -10 * t / d) + 1) + b
	end
end
local function inOutExpo(t, b, c, d)
	if t == 0 then return b end
	if t == d then return b + c end
	t = t / d * 2
	if t < 1 then
		return c / 2 * math.pow(2, 10 * (t - 1)) + b - c * 0.0005
	else
		t = t - 1
		return c / 2 * 1.0005 * (-math.pow(2, -10 * t) + 2) + b
	end
end
local function outInExpo(t, b, c, d)
	if t < d / 2 then
		return outExpo(t * 2, b, c / 2, d)
	else
		return inExpo((t * 2) - d, b + c / 2, c / 2, d)
	end
end

module.ExpoIn = function(val)
	return inExpo(val, 0, 1, 1)
end
module.ExpoOut = function(val)
	return outExpo(val, 0, 1, 1)
end
module.ExpoInOut = function(val)
	return inOutExpo(val, 0, 1, 1)
end
module.ExpoOutIn = function(val)
	return outInExpo(val, 0, 1, 1)
end

local function inCirc(t, b, c, d)
	t = t / d
	return(-c * (math.sqrt(1 - math.pow(t, 2)) - 1) + b)
end
local function outCirc(t, b, c, d)
	t = t / d - 1
	return(c * math.sqrt(1 - math.pow(t, 2)) + b)
end
local function inOutCirc(t, b, c, d)
	t = t / d * 2
	if t < 1 then
		return -c / 2 * (math.sqrt(1 - t * t) - 1) + b
	else
		t = t - 2
		return c / 2 * (math.sqrt(1 - t * t) + 1) + b
	end
end
local function outInCirc(t, b, c, d)
	if t < d / 2 then
		return outCirc(t * 2, b, c / 2, d)
	else
		return inCirc((t * 2) - d, b + c / 2, c / 2, d)
	end
end

module.CircIn = function(val)
	return inCirc(val, 0, 1, 1)
end
module.CircOut = function(val)
	return outCirc(val, 0, 1, 1)
end
module.CircInOut = function(val)
	return inOutCirc(val, 0, 1, 1)
end
module.CircOutIn = function(val)
	return outInCirc(val, 0, 1, 1)
end

local function inBack(t, b, c, d, s)
	if not s then s = 1.70158 end
	t = t / d
	return c * t * t * ((s + 1) * t - s) + b
end
local function outBack(t, b, c, d, s)
	if not s then s = 1.70158 end
	t = t / d - 1
	return c * (t * t * ((s + 1) * t + s) + 1) + b
end
local function inOutBack(t, b, c, d, s)
	if not s then s = 1.70158 end
	s = s * 1.525
	t = t / d * 2
	if t < 1 then
		return c / 2 * (t * t * ((s + 1) * t - s)) + b
	else
		t = t - 2
		return c / 2 * (t * t * ((s + 1) * t + s) + 2) + b
	end
end
local function outInBack(t, b, c, d, s)
	if t < d / 2 then
		return outBack(t * 2, b, c / 2, d, s)
	else
		return inBack((t * 2) - d, b + c / 2, c / 2, d, s)
	end
end

module.BackIn = function(val, s)
	return inBack(val, 0, 1, 1, s)
end
module.BackOut = function(val, s)
	return outBack(val, 0, 1, 1, s)
end
module.BackInOut = function(val, s)
	return inOutBack(val, 0, 1, 1, s)
end
module.BackOutIn = function(val, s)
	return outInBack(val, 0, 1, 1, s)
end

local function outBounce(t, b, c, d)
	t = t / d
	if t < 1 / 2.75 then
		return c * (7.5625 * t * t) + b
	elseif t < 2 / 2.75 then
		t = t - (1.5 / 2.75)
		return c * (7.5625 * t * t + 0.75) + b
	elseif t < 2.5 / 2.75 then
		t = t - (2.25 / 2.75)
		return c * (7.5625 * t * t + 0.9375) + b
	else
		t = t - (2.625 / 2.75)
		return c * (7.5625 * t * t + 0.984375) + b
	end
end
local function inBounce(t, b, c, d)
	return c - outBounce(d - t, 0, c, d) + b
end
local function inOutBounce(t, b, c, d)
	if t < d / 2 then
		return inBounce(t * 2, 0, c, d) * 0.5 + b
	else
		return outBounce(t * 2 - d, 0, c, d) * 0.5 + c * .5 + b
	end
end
local function outInBounce(t, b, c, d)
	if t < d / 2 then
		return outBounce(t * 2, b, c / 2, d)
	else
		return inBounce((t * 2) - d, b + c / 2, c / 2, d)
	end
end

module.BounceIn = function(val)
	return inBounce(val, 0, 1, 1)
end
module.BounceOut = function(val)
	return outBounce(val, 0, 1, 1)
end
module.BounceInOut = function(val)
	return inOutBounce(val, 0, 1, 1)
end
module.BounceOutIn = function(val)
	return outInBounce(val, 0, 1, 1)
end

local function elastic_blend(t, c, d, a, s, f)
	if c ~= 0 then
		local t_ = math.abs(s)
		if a ~= 0 then
			f = f * (a / math.abs(c))
		else
			f = 0
		end
		if math.abs(t * d) < t_ then
			local l = math.abs(t * d) / t_
			f = (f * l) + (1 - l)
		end
	end
	return f
end
local function inElastic(t, b, c, d, a, p)
	local s
	local f = 1

	if t == 0 then return b end
	t = t / d
	if t == 1 then return b + c end
	t = t - 1
	if not p or p == 0 then p = d * 0.3 end
	if not a or a < math.abs(c) then
		s = p / 4
		a = a or 0
		f = elastic_blend(t, c, d, a, s, f)
		a = c
	else
		s = p / (2 * math.pi) * math.asin(c/a)
	end

	return (-f * (a * math.pow(2, 10 * t) * math.sin((t * d - s) * (2 * math.pi) / p))) + b
end
local function outElastic(t, b, c, d, a, p)
	local s
	local f = 1

	if t == 0 then return b end
	t = t / d
	if t == 1 then return b + c end
	t = -t
	if not p or p == 0 then p = d * 0.3 end
	if not a or a < math.abs(c) then
		s = p / 4
		a = a or 0
		f = elastic_blend(t, c, d, a, s, f)
		a = c
	else
		s = p / (2 * math.pi) * math.asin(c/a)
	end
	return (f * (a * math.pow(2, 10 * t) * math.sin((t * d - s) * (2 * math.pi) / p))) + c + b
end
local function inOutElastic(t, b, c, d, a, p)
	local s
	local f = 1

	if t == 0 then return b end
	t = t / (d / 2)
	if t == 2 then return b + c end
	t = t - 1
	if not p or p == 0 then p = d * (0.3 * 1.5) end
	if not a or a < math.abs(c) then
		s = p / 4
		a = a or 0
		f = elastic_blend(t, c, d, a, s, f)
		a = c
	else
		s = p / (2 * math.pi) * math.asin(c / a)
	end
	if t < 0 then
		f = f * -0.5
		return (f * (a * math.pow(2, 10 * t) * math.sin((t * d - s) * (2 * math.pi) / p))) + b
	else
		t = -t
		f = f * 0.5
		return (f * (a * math.pow(2, 10 * t) * math.sin((t * d - s) * (2 * math.pi) / p))) + c + b
	end
end
local function outInElastic(t, b, c, d, a, p)
	if t < d / 2 then
		return outElastic(t * 2, b, c / 2, d, a, p)
	else
		return inElastic((t * 2) - d, b + c / 2, c / 2, d, a, p)
	end
end

module.ElasticIn = function(val, a, p)
	p = p or 0.3
	return inElastic(val, 0, 1, 1, a, p)
end
module.ElasticOut = function(val, a, p)
	p = p or 0.3
	return outElastic(val, 0, 1, 1, a, p)
end
module.ElasticInOut = function(val, a, p)
	p = p or 0.3
	return inOutElastic(val, 0, 1, 1, a, p)
end
module.ElasticOutIn = function(val, a, p)
	p = p or 0.3
	return outInElastic(val, 0, 1, 1, a, p)
end
-------------

return module
