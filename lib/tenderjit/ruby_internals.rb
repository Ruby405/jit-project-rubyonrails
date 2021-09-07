# frozen_string_literal: true

require "rbconfig"
require "worf"
require "odinflex/mach-o"
require "odinflex/ar"
require "fiddle"
require "fiddle/struct"

class TenderJIT
  class RubyInternals
    class Internals
      include Fiddle

      attr_reader :encoded_instructions, :instruction_lengths

      class Fiddle::Function
        def to_proc
          this = self
          lambda { |*args| this.call(*args) }
        end
      end unless Function.method_defined?(:to_proc)

      def self.make_function name, args, ret
        ptr = Handle::DEFAULT[name]
        func = Function.new ptr, args, ret, name: name
        define_method name, &func.to_proc
      end

      make_function "rb_id2sym", [TYPE_INT], TYPE_VOIDP
      make_function "rb_callable_method_entry", [TYPE_VOIDP, TYPE_INT], TYPE_VOIDP

      module GCC
        def self.read_instruction_lengths symbol_addresses
          # Instruction length tables seem to be compiled with numbers, and
          # embedded multiple times. Try to find the first one that has
          # the data we need
          symbol_addresses.keys.grep(/^t\.\d+/).each do |key|
            addr = symbol_addresses.fetch(key)
            len  = RubyVM::INSTRUCTION_NAMES.length
            list = Fiddle::Pointer.new(addr)[0, len * Fiddle::SIZEOF_CHAR].unpack("C#{len}")

            # This is probably it
            if list.first(4) == [1, 3, 3, 3]
              return list
            end
          end
        end

        def self.read_instruction_op_types symbol_addresses
          len  = RubyVM::INSTRUCTION_NAMES.length

          map = symbol_addresses.keys.grep(/^y\.\d+/).each do |key|
            insn_map = symbol_addresses.fetch(key)
            l = Fiddle::Pointer.new(insn_map)[0, len * Fiddle::SIZEOF_SHORT].unpack("S#{len}")
            break l if l.first(4) == [0, 1, 4, 7] # probably the right one
          end

          key = symbol_addresses.keys.grep(/^x\.\d+/).first
          op_types = symbol_addresses.fetch(key)

          str_buffer_end = map.last

          while Fiddle::Pointer.new(op_types + str_buffer_end)[0] != 0
            str_buffer_end += 1
          end
          Fiddle::Pointer.new(op_types)[0, str_buffer_end].unpack("Z*" * len)
        end
      end

      module Clang
      end

      def initialize symbol_addresses, constants, structs, unions
        @symbol_addresses     = symbol_addresses
        @constants            = constants
        @structs              = structs
        @unions               = unions

        decoder = case RbConfig::CONFIG["CC"]
                  when "clang" then Clang
                  when "gcc" then  GCC
                  else
                    raise NotImplementedError, "Unknown compiler #{RbConfig::CONFIG["CC"]}"
                  end

        @encoded_instructions = read_encoded_instructions(symbol_addresses)
        @instruction_lengths  = decoder.read_instruction_lengths(symbol_addresses)
        @instruction_ops      = decoder.read_instruction_op_types(symbol_addresses)

        @insn_to_name         = Hash[@encoded_instructions.zip(RubyVM::INSTRUCTION_NAMES)]
        @insn_len             = Hash[@encoded_instructions.zip(@instruction_lengths)]
        @insn_to_ops          = Hash[@encoded_instructions.zip(@instruction_ops)]
      end

      def RB_IMMEDIATE_P obj_addr
        (obj_addr & RUBY_IMMEDIATE_MASK) != 0
      end

      def RB_TEST obj_addr
        (obj_addr & ~Qnil) != 0
      end

      def RB_SPECIAL_CONST_P obj_addr
        self.RB_IMMEDIATE_P(obj_addr) || !self.RB_TEST(obj_addr)
      end

      def RB_FIXNUM_P obj_addr
        0 != obj_addr & RUBY_FIXNUM_FLAG
      end

      def RB_BUILTIN_TYPE obj_addr
        raise if RB_SPECIAL_CONST_P(obj_addr)

        RBasic.flags(obj_addr) & RUBY_T_MASK
      end

      def insn_name encoded_name
        @insn_to_name.fetch encoded_name
      end

      def insn_len encoded_name
        @insn_len.fetch encoded_name
      end

      def insn_op_types encoded_name
        @insn_to_ops.fetch encoded_name
      end

      def read_instruction_op_types symbol_addresses
        # FIXME: this needs to be tested on Linux, certainly the name will be
        # different.
        op_types = symbol_addresses.fetch("insn_op_types.x")

        insn_map = symbol_addresses.fetch("insn_op_types.y")

        # FIXME: we should use DWARF data to figure out the array type rather
        # than hardcoding "sizeof short" below
        len  = RubyVM::INSTRUCTION_NAMES.length
        l = Fiddle::Pointer.new(insn_map)[0, len * SIZEOF_SHORT].unpack("S#{len}")
        str_buffer_end = l.last

        while Fiddle::Pointer.new(op_types + str_buffer_end)[0] != 0
          str_buffer_end += 1
        end
        Fiddle::Pointer.new(op_types)[0, str_buffer_end].unpack("Z*" * len)
      end

      def read_instruction_lengths symbol_addresses
        # FIXME: this needs to be tested on Linux, certainly the name will be
        # different.
        addr = symbol_addresses.fetch("insn_len.t")

        # FIXME: we should use DWARF data to figure out the array type rather
        # than hardcoding "sizeof char" below
        len  = RubyVM::INSTRUCTION_NAMES.length
        Fiddle::Pointer.new(addr)[0, len * SIZEOF_CHAR].unpack("C#{len}")
      end

      def read_encoded_instructions symbol_addresses
        addr = symbol_addresses["rb_vm_get_insns_address_table"]
        func = Fiddle::Function.new(addr, [], TYPE_VOIDP)
        buf  = func.call
        len  = RubyVM::INSTRUCTION_NAMES.length
        buf[0, len * SIZEOF_VOIDP].unpack("Q#{len}")
      end

      def symbol_address name
        @symbol_addresses[name]
      end

      def c name
        @constants.fetch name
      end

      def constants
        @constants.keys
      end

      def struct name
        @structs.fetch name
      end
    end

    def self.ruby_archive
      File.join RbConfig::CONFIG["prefix"], "lib", RbConfig::CONFIG["LIBRUBY_A"]
    end

    def self.ruby_so
      File.join RbConfig::CONFIG["prefix"], "lib", RbConfig::CONFIG["LIBRUBY_SO"]
    end

    def self.libruby
      File.join RbConfig::CONFIG["prefix"], "lib", RbConfig::CONFIG["LIBRUBY"]
    end

    module MachOSystem
      class Base
        def process
          constants = {}
          structs = {}
          unions = {}

          each_compile_unit do |cu, strings|
            case cu.die.name(strings)
            when "debug.c"
              cu.die.find_all { |x| x.tag.enumerator? }.each do |enum|
                name = enum.name(strings).delete_prefix("RUBY_")
                constants[name] = enum.const_value
              end
            else
              builder = TypeBuilder.new(cu, strings)
              builder.build
              structs.merge! builder.structs
              unions.merge! builder.unions
              constants.merge! builder.enums
            end
          end

          Internals.new(find_symbols, constants, structs, unions)
        end

        private

        def each_compile_unit
          each_object_file do |f|
            # Get the DWARF info from each object file
            macho = OdinFlex::MachO.new f

            info = strs = abbr = nil

            macho.each do |thing|
              if thing.section?
                case thing.sectname
                when "__debug_info"
                  info = thing.as_dwarf
                when "__debug_str"
                  strs = thing.as_dwarf
                when "__debug_abbrev"
                  abbr = thing.as_dwarf
                else
                end
              end

              break if info && strs && abbr
            end

            if info && strs && abbr
              info.compile_units(abbr.tags).each do |unit|
                yield unit, strs
              end
            end
          end
        end

        def find_symbols
          symbol_addresses = {}

          File.open symbol_file do |f|
            my_macho = OdinFlex::MachO.new f

            my_macho.each do |section|
              if section.symtab?
                section.nlist.each do |item|
                  unless item.archive?
                    name = item.name.delete_prefix(RbConfig::CONFIG["SYMBOL_PREFIX"])
                    symbol_addresses[name] = item.value if item.value > 0
                  end
                end
              end
            end
          end

          # Fix up addresses due to ASLR
          slide = Fiddle::Handle::DEFAULT["rb_st_insert"] - symbol_addresses.fetch("rb_st_insert")
          symbol_addresses.transform_values! { |v| v + slide }

          symbol_addresses
        end
      end

      class SharedObject < Base
        attr_reader :symbol_file

        def initialize libruby
          @symbol_file = libruby
        end

        private

        def each_object_file
          # Find all object files from the shared object
          object_files = File.open(symbol_file) do |f|
            my_macho = OdinFlex::MachO.new f
            my_macho.find_all(&:symtab?).flat_map do |section|
              section.nlist.find_all(&:oso?).map(&:name)
            end
          end

          object_files.grep(/(?:debug|iseq|gc|st|vm|mjit)\.[oc]$/).each do |f|
            File.open(f) { |fd| yield fd }
          end
        end
      end

      class Archive < Base
        attr_reader :symbol_file

        def initialize ruby_archive
          @ruby_archive = ruby_archive
          @symbol_file = RbConfig.ruby
        end

        private

        def each_object_file
          File.open @ruby_archive do |archive|
            ar = OdinFlex::AR.new archive
            ar.each do |object_file|
              next unless object_file.identifier =~ /(?:debug|iseq|gc|st|vm|mjit)\.[oc]$/

              yield archive
            end
          end
        end
      end
    end

    module ELFSystem
      ELFAdapter = Struct.new(:offset, :size)

      class Base
        def process
          constants = {}
          structs = {}
          unions = {}

          each_compile_unit do |cu, strings|
            case cu.die.name(strings)
            when "debug.c"
              cu.die.find_all { |x| x.tag.enumerator? }.each do |enum|
                name = enum.name(strings).delete_prefix("RUBY_")
                constants[name] = enum.const_value
              end
            else
              builder = TypeBuilder.new(cu, strings)
              builder.build
              structs.merge! builder.structs
              unions.merge! builder.unions
              constants.merge! builder.enums
            end
          end

          Internals.new(find_symbols, constants, structs, unions)
        end

        private

        SHF_COMPRESSED = 1 << 11

        def read_section klass, file, section
          klass.new(file, ELFAdapter.new(section.header.sh_offset,
                                         section.header.sh_size), 0)
        end

        def read_compressed klass, file, section
          require "zlib"
          require "stringio"

          elf64_Chdr = [
            Fiddle::SIZEOF_INT, # Elf64_Word   ch_type;        /* Compression format.  */
            Fiddle::SIZEOF_INT, # Elf64_Word   ch_reserved;
            Fiddle::SIZEOF_LONG, # Elf64_Xword  ch_size;        /* Uncompressed data size.  */
            Fiddle::SIZEOF_LONG, # Elf64_Xword  ch_addralign;   /* Uncompressed data alignment.  */
          ]

          file.seek section.header.sh_offset, IO::SEEK_SET

          # Zlib info is _after_ the chdr header
          #type, _, size, align = file.read(elf64_Chdr.inject(:+)).unpack("IILL")
          _, _, size, _ = file.read(elf64_Chdr.inject(:+)).unpack("IILL")

          data = file.read section.header.sh_size

          data = Zlib.inflate(data)

          raise "Wrong data size" unless data.bytesize == size

          file = StringIO.new data

          klass.new(file, ELFAdapter.new(0, size), 0)
        end

        def read_dwarf section_name, klass, elf, file
          section  = elf.section_by_name(section_name)
          if section.header.sh_flags & SHF_COMPRESSED == SHF_COMPRESSED
            read_compressed klass, file, section
          else
            read_section klass, file, section
          end
        end

        def each_compile_unit
          File.open(@dwarf_file) do |f|
            elf = ELFTools::ELFFile.new f

            info = read_dwarf ".debug_info", WORF::DebugInfo, elf, f
            abbr = read_dwarf ".debug_abbrev", WORF::DebugAbbrev, elf, f
            strs = read_dwarf ".debug_str", WORF::DebugStrings, elf, f

            info.compile_units(abbr.tags).each do |unit|
              name = unit.die.name(strs)
              next unless name =~ /(?:debug|iseq|gc|st|vm|mjit)\.[oc]$/
              yield unit, strs
            end
          end
        end

        def find_symbols
          symbol_addresses = {}

          File.open(@symbol_file) do |f|
            elf = ELFTools::ELFFile.new f
            symtab_section = elf.section_by_name '.symtab'
            symtab_section.symbols.each do |item|
              name = item.name.delete_prefix(RbConfig::CONFIG["SYMBOL_PREFIX"])
              val = item.header.st_value
              symbol_addresses[name] = val
            end
          end

          # Fix up addresses due to ASLR
          slide = Fiddle::Handle::DEFAULT["rb_st_insert"] - symbol_addresses.fetch("rb_st_insert")
          symbol_addresses.transform_values! { |v| v + slide }

          symbol_addresses
        end
      end

      class SharedObject < Base
        def initialize ruby_so
          @symbol_file = ruby_so
          @dwarf_file = ruby_so
        end
      end

      class Archive < Base
        def initialize ruby_archive
          @symbol_file = RbConfig.ruby
          @dwarf_file = RbConfig.ruby
        end
      end
    end

    def self.get_internals
      base_system = if RUBY_PLATFORM =~ /darwin/
                      MachOSystem
                    else
                      require "elftools"
                      ELFSystem
                    end

      # Ruby was built as a shared object.  We'll ask it for symbols
      info_strat = if libruby == ruby_so
                     base_system.const_get(:SharedObject).new(libruby)
                   else
                     base_system.const_get(:Archive).new(ruby_archive)
                   end

      info_strat.process
    end

    class TypeBuilder
      Type = Struct.new(:die, :fiddle)

      attr_reader :known_types, :structs, :unions, :enums, :strs

      def initialize cu, strs
        @cu                  = cu
        @strs                = strs
        @known_types         = []
        @structs             = {}
        @unions              = {}
        @function_signatures = {}
        @enums               = {}
      end

      def make_decorator mod, name, type
        mod.define_method(name) { type.new(super()) }
      end

      def build
        unit = @cu
        top = unit.die
        all_dies = top.to_a
        top.children.each do |die|
          next if die.tag.user?
          find_or_build die, all_dies
        end

        # Add decorators to each struct that automatically cast pointers to
        # the struct type we want.  That way we don't have to manually keep
        # adding types.
        @structs.each_value do |struct|
          ref_structs = struct.instance_variable_get(:@reference_structs)
          if ref_structs
            mod = Module.new
            ref_structs.each do |member_name, type|
              if @structs.key? type
                make_decorator(mod, member_name, @structs[type])
              end
            end
            struct.prepend mod
          end
        end
        @known_types.compact.each_with_object({}) do |type, hash|
          name = type.die.name(strs)
          hash[name] = type.fiddle if name
        end
      end

      def handle_typedef die, all_dies
        name = die.name(@strs)
        type = find_type_die(die, all_dies)
        if type && type.tag.identifier == :DW_TAG_structure_type
          @structs[name] = find_or_build type, all_dies
        end
      end

      def find_or_build die, all_dies
        object = @known_types[die.offset]
        return object.fiddle if object

        case die.tag.identifier
        when :DW_TAG_structure_type
          if die.tag.has_children?
            name = die.name(@strs)

            fiddle = build_fiddle(die, all_dies, Fiddle::CStruct)
            @known_types[die.offset] = Type.new(die, fiddle)
            @structs[name] = fiddle if name
            fiddle
          end
        when :DW_TAG_union_type
          if die.tag.has_children?
            fiddle = build_fiddle(die, all_dies, Fiddle::CUnion)
            name = die.name(@strs)
            @known_types[die.offset] = Type.new(die, fiddle)
            @unions[name] = fiddle if name
            fiddle
          end
        when :DW_TAG_array_type
          fiddle = build_array die, all_dies
          @known_types[die.offset] = Type.new(die, fiddle)
          fiddle
        #when :DW_TAG_subprogram
        #  name = die.name(@debug_strs)
        #  return_type = find_fiddle_type find_type_die(die, all_dies), all_dies
        #  param_types = die.children.map { |x|
        #    find_fiddle_type find_type_die(x, all_dies), all_dies
        #  }
        #  @function_signatures[name] = [param_types, return_type]
        when :DW_TAG_typedef
          handle_typedef die, all_dies
        when :DW_TAG_enumeration_type
          die.children.each do |child|
            name = child.name(@strs)
            @enums[name] = child.const_value
          end
        end
      end

      def build_array die, all_dies
        type = find_fiddle_type find_type_die(die, all_dies), all_dies
        [type, die.count + 1]
      end

      DWARF_TO_FIDDLE = {
        "int"                    => Fiddle::TYPE_INT,
        "char"                   => Fiddle::TYPE_CHAR,
        "signed char"            => Fiddle::TYPE_CHAR,
        "short"                  => Fiddle::TYPE_SHORT,
        "short int"              => Fiddle::TYPE_SHORT,
        "unsigned short"         => -Fiddle::TYPE_SHORT,
        "short unsigned int"     => -Fiddle::TYPE_SHORT,
        "unsigned char"          => -Fiddle::TYPE_CHAR,
        "long long int"          => Fiddle::TYPE_LONG_LONG,
        "long long unsigned int" => -Fiddle::TYPE_LONG_LONG,
        "unsigned int"           => -Fiddle::TYPE_INT,
        "long unsigned int"      => -Fiddle::TYPE_LONG,
        "double"                 => Fiddle::TYPE_DOUBLE,
        "long int"               => Fiddle::TYPE_LONG,
        "_Bool"                  => Fiddle::TYPE_CHAR,
        "float"                  => Fiddle::TYPE_FLOAT,
      }

      def find_type_die die, all_dies
        all_dies.bsearch { |c| die.type <=> c.offset }
      end

      def find_fiddle_type type_die, all_dies
        case type_die.tag.identifier
        when :DW_TAG_pointer_type
          Fiddle::TYPE_VOIDP
        when :DW_TAG_base_type
          name = type_die.name(strs)
          DWARF_TO_FIDDLE.fetch name
        when :DW_TAG_const_type, :DW_TAG_volatile_type, :DW_TAG_enumeration_type, :DW_TAG_typedef
          if type_die.type
            sub_type = find_type_die(type_die, all_dies)
            find_fiddle_type sub_type, all_dies
          else
            raise
          end
        when :DW_TAG_structure_type
          find_or_build type_die, all_dies
        when :DW_TAG_array_type
          find_or_build type_die, all_dies
        when :DW_TAG_union_type
          find_or_build type_die, all_dies
        else
          raise "unknown member type #{type_die.tag.identifier}"
        end
      end

      def make_bitread_method loc, byte_size, bit_offset, bit_size
        raise "Unsupported bitfield size" unless byte_size == Fiddle::SIZEOF_INT

        bits = byte_size * 8

        lambda {
          mask = 0xFFFFFFFF
          bitfield = to_ptr[loc, Fiddle::SIZEOF_INT].unpack1("i!")
          bitfield = mask & (bitfield << bit_offset)
          bitfield >> (bit_offset + (bits - (bit_size + bit_offset)))
        }
      end

      def make_d5bitread_method name, bit_offset, bit_size
        # We need to read ints, so round down to the next 32bit number then
        int_bits = Fiddle::SIZEOF_INT * 8
        aligned_offset = ((bit_offset >> 5) << 5)
        buffer_loc = (aligned_offset / int_bits) * Fiddle::SIZEOF_INT

        lambda {
          bitfield = to_ptr[buffer_loc, Fiddle::SIZEOF_INT].unpack1("i!")
          bitfield >>= (bit_offset - aligned_offset)
          bitfield & ((1 << bit_size) - 1)
        }
      end

      def build_fiddle die, all_dies, fiddle_type
        types = []
        names = []
        reference_structs = {}

        bitfield_methods = nil

        last_offset = -1
        die.children.each do |child|
          case child.tag.identifier
          when :DW_TAG_member
            name = child.name(strs) || "__anonymous"

            type = find_type_die(child, all_dies)

            if child.bit_offset # bitfields for DWARF 4
              bitfield_methods ||= Module.new
              x = make_bitread_method(child.data_member_location,
                                      child.byte_size,
                                      child.bit_offset,
                                      child.bit_size)

              bitfield_methods.define_method(name, &x)
            end

            if child.data_bit_offset
              bitfield_methods ||= Module.new
              x = make_d5bitread_method(name, child.data_bit_offset, child.bit_size)

              bitfield_methods.define_method(name, &x)
            end

            # deal with bitfield memebers
            if child.data_member_location == last_offset && fiddle_type == Fiddle::CStruct
              names.last << "|#{name}"
            else
              last_offset = child.data_member_location
              fiddle_subtype = find_fiddle_type(type, all_dies)
              if fiddle_subtype.is_a?(Class)
                names << [name, fiddle_subtype.members]
              else
                if type.tag.identifier == :DW_TAG_pointer_type
                  pointer_type = find_type_die(type, all_dies)
                  if pointer_type && pointer_type.tag.identifier == :DW_TAG_structure_type
                    reference_structs[name] = pointer_type.name(strs)
                  end
                end
                names << name
              end
              types << fiddle_subtype
            end
          when :DW_TAG_structure_type, :DW_TAG_union_type, :DW_TAG_enumeration_type
            # we can ignore sub structures. They should be built out
            # when the named member finds them
            # we can ignore sub structures. They should be built out
            # when the named member finds them
          else
            raise "unhandled type #{child.tag.identifier}"
          end
        end

        klass = Fiddle::CStructBuilder.create(fiddle_type, types, names)
        # if this class references any structs, add the member name / type
        # hash to the class.
        if reference_structs.size > 0
          klass.instance_variable_set(:@reference_structs, reference_structs)
        end
        klass.include(bitfield_methods) if bitfield_methods
        klass
      end
    end
  end
end
