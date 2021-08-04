ENV["MT_NO_PLUGINS"] = "1"

require "minitest/autorun"
require "tenderjit"
require "tenderjit/ruby_internals"
require "rbconfig"
require "fisk"
require "fisk/helpers"

class TenderJIT
  class Test < Minitest::Test
    include Fiddle

    module Hacks
      include Fiddle

      class Fiddle::Function
        def to_proc
          this = self
          lambda { |*args| this.call(*args) }
        end
      end unless Function.method_defined?(:to_proc)

      def self.make_function name, args, ret
        ptr = Handle::DEFAULT[name]
        func = Function.new ptr, args, ret, name: name
        define_singleton_method name, &func.to_proc
      end

      make_function "strerror", [TYPE_INT], TYPE_CONST_STRING
      #make_function "mprotect", [TYPE_VOIDP, TYPE_SIZE_T, TYPE_INT], TYPE_INT
      make_function "_dyld_image_count", [], TYPE_INT32_T
      make_function "_dyld_get_image_name", [TYPE_INT32_T], TYPE_CONST_STRING
      make_function "_dyld_get_image_vmaddr_slide", [TYPE_INT32_T], TYPE_INTPTR_T
      make_function "mach_task_self", [], TYPE_VOIDP
      make_function "vm_protect", [TYPE_VOIDP, -TYPE_INT64_T, TYPE_SIZE_T, TYPE_CHAR, TYPE_INT], TYPE_INT
      make_function "rb_intern", [TYPE_CONST_STRING], TYPE_INT

      def self.mprotect addr, len, prot
        vm_protect mach_task_self, addr, len, 0, prot | PROT_COPY
      end

      PROT_READ   = 0x01
      PROT_WRITE  = 0x02
      PROT_EXEC   = 0x04
      PROT_COPY   = 0x10

      def self.slide
        executable = RbConfig.ruby
        Hacks._dyld_image_count.times do |i|
          name = Hacks._dyld_get_image_name(i)
          if executable == name
            return Hacks._dyld_get_image_vmaddr_slide(i)
          end
        end
      end

      fisk = Fisk.new

      jitbuf = Fisk::Helpers.jitbuffer 4096

      fisk.asm(jitbuf) do
        push rbp
        mov rbp, rsp
        int lit(3)
        pop rbp
        ret
      end

      define_singleton_method :halt!, &jitbuf.to_function([], Fiddle::TYPE_VOID)
    end
  end

  class JITTest < Test
    def assert_jit method, compiled:, executed:, exits:
      jit = TenderJIT.new
      jit.compile method

      assert_equal compiled, jit.compiled_methods
      before_executed = jit.executed_methods

      jit.enable!
      v = method.call
      jit.disable!

      assert_equal compiled, jit.compiled_methods
      assert_equal executed, jit.executed_methods - before_executed
      assert_equal exits, jit.exits
      v
    end

    def teardown
      super
      self.class.instance_methods(false).each do |m|
        next if m.to_s =~ /^test_/

        meth = method m
        TenderJIT.uncompile(meth) if TenderJIT.compiled?(meth)
      end
    end
  end
end
