
require_relative 'Instructions'

class MiniAssembler

	# applesoft has a limit of 236 chars / line. 236/4 = 59.
	CHUNK_SIZE = 50

	M6502 = 0
	M65C02 = 1
	M65816 = 2

	EQU = :'.equ'
	ORG = :'.org'
	MACHINE = :'.machine'
	LONG = :'.long'
	SHORT = :'.short'
	POKE = :'.poke'
	EXPORT = :'.export'

	COLON = :':'
	GT = :'>'
	LT = :'<'
	LPAREN = :'('
	RPAREN = :')'
	LBRACKET = :'['
	RBRACKET = :']'
	PIPE = :'|'
	COMMA = :','
	STAR = :'*'
	POUND = :'#'


	def initialize(args = nil)
		reset()
	end

	def reset
		@pc = 0
		@org = 0
		@m = 0
		@x = 0
		@machine = M6502
		@data = []
		@symbols = {}
		@exports = {}
		@patches = []
		@poke = false
	end


	def process(line)
		line.chomp!

		data = self.class.parse(line)
		return unless data
		label, opcode, operand = data

		case opcode

		when nil
			# insert a label w/ the current pc.
			value = @pc
			if @symbols.has_key? label && @symbols[label] != value
				raise "Attempt to redefine symbol #{label}"
			end

			@symbols[label] = value				

		when ORG
			raise "org already set" if @pc != @org
			@org = @pc = self.class.expect_number(operand)

		when MACHINE
			@machine = self.class.expect_machine(operand)

		when LONG
			raise "invalid opcode" unless @machine = M65816
			value = self.class.expect_mx(operand)
			@m ||= value.includes? ?m
			@x ||= value.includes? ?x

		when SHORT
			raise "invalid opcode" unless @machine = M65816
			value = self.class.expect_mx(operand)
			@m = false if value.includes? ?m
			@x = false if value.includes? ?x

		when POKE
			self.class.expect_nil(operand)
			@poke = true

		when EQU
			unless label.nil?
				value = self.class.expect_number(operand, @symbols)

				if @symbols.has_key? label && @symbols[label] != value
					raise "Attempt to redefine symbol #{label}"
				end

				@symbols[label] = value
			end

			# .export symbol [, ...]
		when EXPORT
			self.class.expect_symbol_list(operand).each {|x|
				@exports[x] = true
			}

		when :mvp, :mvn
			if label
				value = @pc
				if @symbols.has_key? label && @symbols[label] != value
					raise "Attempt to redefine symbol #{label}"
				end

				@symbols[label] = value
			end
			do_instruction(opcode, self.class.expect_block_operand(operand))


		else

			if label
				value = @pc
				if @symbols.has_key? label && @symbols[label] != value
					raise "Attempt to redefine symbol #{label}"
				end

				@symbols[label] = value
			end

			do_instruction(opcode, self.class.expect_operand(operand))


		end

		return true
	end

	def do_instruction(opcode, operand)

		value = operand[:value]
		mode = operand[:mode]

		# todo -- if mode == :block, value is array of 2 elements.

		if Symbol === value
			if @symbols.has_key? value
				value = @symbols[value]
			end
		end

		# implicit absolute < 256 -> zp
		if Integer === value && value < 256 && !operand[:explicit]

			mode = case mode
			when :absolute ; :zp
			when :absolute_x ; :zp_x
			when :absolute_y ; :zp_y
			else ; mode
			end

		end


		instr = Instructions.lookup(opcode, mode, operand[:explicit], @machine)

		mode = instr[:mode]
		size = instr[:size]

		@data.push instr[:opcode]
		@pc = @pc + 1

		size = size + 1 if @machine == M65816 && instr[:m] && @m
		size = size + 1 if @machine == M65816 && instr[:x] && @x

		if Symbol === value
			@patches.push( { :pc => @pc, :size => size, :value => value, :mode => mode } )
			size.times { @data.push 0 }
		else

			if mode == :relative
				# fudge value...
				value = value - (@pc + size)
				if size == 1
					if value < -128 || value > 127
						@data.pop
						@pc = @pc - 1
						raise "relative branch out of range"
					end
				end
				value = value & 0xffff
			end

			size.times { 
				@data.push value & 0xff
				value = value >> 8
			}

		end
		@pc = @pc + size

	end


	def self.parse(line)

		label = nil
		operand = nil
		opcode = nil

		return nil if line.empty?
		return nil if line =~ /^[*;]/


		# remove ; comments...
		re = /
			^
			((?: [^;'"] | "[^"]*" | '[^']*' )*)
			(.*?)
			$
			/x


		if line =~ re
			line = $1.rstrip
			x = $2
			raise "unterminated string" unless x.empty? || x[0] == ?; 
		else
			raise "lexical error"
		end

		return nil if line.empty?

		if line =~ /^([A-Za-z_][A-Za-z0-9_]*)/
			label = $1.intern
			line = $' # string after match
		end

		line.lstrip!


		if line =~ /^(\.?[A-Za-z_][A-Za-z0-9_]*)/
			opcode = $1.downcase.intern

			line = $' # string after match
			line.lstrip!
			operand = line unless line.empty?
		end

		return [label, opcode, operand]

	end


	def self.expect_nil(operand)
		return nil if operand.nil?
		raise "bad operand: #{operand}"
	end

	def self.expect_mx(operand)
		return 'mx' if operand.nil? || operand == ''
		operand.downcase!
		return operand.gsub(/[^mx]/, '') if operand =~ /^[mx, ]+$/
		raise "bad operand #{operand}"
	end

	def self.expect_machine(operand)
		case operand.downcase
		when '6502' ; return M6502
		when '65c02' ; return M65C02
		when '65816' ; return M65816
		end
		raise "bad operand #{operand}"
	end

	def self.expect_number(operand, st = nil)
		case operand
		when /^\$([A-Fa-f0-9]+)$/ ; return $1.to_i(16)
		when /^0x([A-Fa-f0-9]+)$/ ; return $1.to_i(16)
		when /^%([01]+)$/ ; return $1.to_i(2)
		when /^[0-9]+$/ ; return operand.to_i(10)

		when /^[A-Za-z_][A-Za-z0-9_]*$/
			if st
				key = operand.downcase.intern
				return st[key] if st.has_key? key
				raise "Undefined symbol #{operand}"
			end

		end
		raise "bad operand #{operand}"
	end

	def self.expect_string(operand)
		case operand
		when /^'([^']+)'$/ ; return $1
		when /^"([^"]+)"$/ ; return $1
		end
		raise "bad operand #{operand}"
	end

	def self.expect_symbol(operand)

		return operand.downcase.intern if operand =~ /^[A-Za-z_][A-Za-z0-9_]*/
		raise "bad operand #{operand}"
	end

	def self.expect_number_list(operand, st = nil)

		return operand.split(',').map { |x| expect_number(x.strip, st) }
	end


	def self.expect_symbol_list(operand)

		return operand.split(',').map {|x| expect_symbol(x.strip) }

		#a = operand.split(',')
		#a.map! { |x| x.strip }

		#raise "bad operand #{operand}" unless a.all? {|x| x =~ /^[A-Za-z_][A-Za-z0-9_]*/ }

		#return a.map { |x| x.downcase.intern }
	end

	def self.tokenize(x)

		rv = []
		while !x.empty?
			case x
			when /^([#,()<>|\[\]])/
				rv.push $1.intern
				x = $'
			when /^0x([A-Fa-f0-9]+)/
				rv.push($1.to_i(16))
				x = $'
			when /^\$([A-Fa-f0-9]+)/
				rv.push($1.to_i(16))
				x = $'
			when /^([0-9]+)/
				rv.push($1.to_i(10))
				x = $'
			when /^([A-Za-z_][A-Za-z0-9_]*)/
				rv.push($1.downcase.intern)
				x = $'
			else
				raise "bad operand #{x}"
			end
			x.lstrip!
		end

		return rv;
	end

	def self.get_mod(tt)
		if [GT, LT, PIPE].include? tt.last
			return tt.pop
		end
		return nil
	end

	def self.parse_expr(tt)
		t = tt.last
		return tt.pop if Symbol === t
		return tt.pop if Integer === t

		# todo -- support expressions.
		raise "expression error"

	end

	def self.expect_block_operand(operand)

		return { :mode => :implied, :explicit => true } if operand.nil? || operand.empty?

		tt = tokenize(operand)

		tt.reverse!

		a = parse_expr(tt)
		raise "syntax error #{operand}" unless tt.last == COMMA
		tt.pop
		b = parse_expr(tt)
		raise "syntax error #{operand}" unless tt.empty?

		return { :mode => :block, :explicit => true, :value => [a,b]}

	end

	def self.expect_operand(operand)

		mode = nil
		explicit = false


		return { :mode => :implied, :explicit => true } if operand.nil? || operand.empty?

		tt = tokenize(operand)

		tt.reverse!

		t = tt.last
		case t

			# # expr
		when POUND
			tt.pop
			e = parse_expr(tt)
			raise "syntax error #{operand}" unless tt.empty?
			explicit = true
			mode = :immediate

			# [expr]
			# [expr] , y
		when LBRACKET

			tt.pop
			modifier = get_mod(tt)
			explicit = !!modifier

			e = parse_expr(tt)

			case tt.reverse
			when [RBRACKET]
				case modifier
				when nil ; mode = :zp_indirect_long
				when LT ; mode = :zp_indirect_long
				when PIPE ; mode = :absolute_indirect_long
				end
			when [RBRACKET , COMMA , :y]
				case modifier
				when nil ; mode = :zp_indirect_long_y
				when LT ; mode = :zp_indirect_long_y
				end
			else
				raise "syntax error #{operand}"
			end

			# ( expr )
			# ( expr ) , y
			# ( expr , x )
			# ( expr , s) , y
		when LPAREN

			tt.pop
			modifier = get_mod(tt)
			explicit = !!modifier

			e = parse_expr(tt)

			case tt.reverse
			when [RPAREN]
				case modifier
				when nil ; mode = :zp_indirect
				when LT ; mode = :zp_indirect
				when PIPE ; mode = :absolute_indirect
				end
			when [RPAREN , COMMA, :y]
				case modifier
				when nil ; mode = :zp_indirect_y
				when LT ; mode = :zp_indirect_y
				end
			when [COMMA , :x, RPAREN]
				case modifier
				when nil ; mode = :zp_indirect_x
				when LT ; mode = :zp_indirect_x
				when PIPE ; mode = :absolute_indirect_x
				end
			when [COMMA , :s, RPAREN , COMMA , :y]
				case modifier
				when nil ; mode = :sr_indirect_y
				when LT ; mode = :sr_indirect_y
				end
			else
				raise "syntax error #{operand}"
			end


			# expr
			# expr , x
			# expr , y
			# expr , s
		else
			modifier = get_mod(tt)
			explicit = !!modifier
			e = parse_expr(tt)

			case tt.reverse
			when []
				case modifier
				when nil ; mode = :absolute
				when LT ; mode = :zp
				when PIPE ; mode = :absolute
				when GT ; mode = :absolute_long
				end

			when [ COMMA, :x]
				case modifier
				when nil ; mode = :absolute_x
				when LT ; mode = :zp_x
				when PIPE ; mode = :absolute_x
				when GT ; mode = :absolute_long_x
				end

			when [ COMMA, :y]
				case modifier
				when nil ; mode = :absolute_y
				when LT ; mode = :zp_y
				when PIPE ; mode = :absolute_y
				end

			when [ COMMA, :s]
				case modifier
				when nil ; mode = :sr
				when LT ; mode = :sr
				end

			else
				raise "syntax error #{operand}"
			end

		end

		raise "invalid address mode" unless mode
		return {:mode => mode, :value => e, :explicit => explicit}


	end

	def finish(code, st)

		# resolve symbols, etc.

		@patches.each {|p|
			pc = p[:pc]
			size = p[:size]
			value = p[:value]
			mode = p[:mode]

			xvalue = @symbols[value] or raise "Undefined symbol #{value}"


			offset = pc - @org
			if mode == :relative

			else
				size.times {
					@data[offset] = xvalue & 0xff
					xvalue = xvalue >> 8
					offset = offset + 1
				}
			end
		}

		pc = @org
		while !@data.empty?


			prefix = @poke ? "& POKE #{pc}," : "DATA "

			tmp = @data.take CHUNK_SIZE

			code.push prefix + tmp.join(',')

			pc += tmp.length

			@data = @data.drop CHUNK_SIZE

		end

		@exports.each {|key, _value|

			st[key] = @symbols[key] if @symbols.has_key? key
		}

		reset
		true
	end


	
end