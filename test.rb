#!/usr/bin/ruby
# -*- coding: UTF-8 -*-
 
af = File.open("Hidden_skill.md", "r")
if af
    af.each_byte {|ch| putc ch;}
end
