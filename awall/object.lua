--[[
Class model with inheritance and morphing support for Alpine Wall
Copyright (C) 2012 Kaarle Ritvanen
Licensed under the terms of GPL2
]]--


module(..., package.seeall)

function class(base)
   local cls = {}
   local mt = {__index = cls}

   if base then setmetatable(cls, {__index = base}) end

   function cls.new(...) return cls.morph({}, unpack(arg)) end

   function cls:morph(...)
      setmetatable(self, mt)
      self:init(unpack(arg))
      return self
   end

   return cls
end

Object = class()

function Object:init(...) end
