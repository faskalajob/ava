from amaranth import *
from amaranth.lib.enum import Enum
from amaranth.lib.memory import Memory

from .stack import Stack
from .uart import UART


__all__ = ["Core"]

HELLO_AVC = [
    # 00
    0x01, 0x02, 0x00,
    # 03
    0x20, 0x00,
    # 05
    0x01, 0x04, 0x00,
    # 08
    0x20, 0x01,
    # 0a
    0x0a, 0x00,
    # 0c
    0x0a, 0x01,
    # 0e
    0xa5,
    # 0f
    0x80,
    # 10
    0x82,
]


class Op(Enum, shape=3):
    ADD = 0
    MULTIPLY = 1
    FDIVIDE = 2
    IDIVIDE = 3
    SUBTRACT = 4
    NEGATE = 5
    # ...


class Type(Enum, shape=3):
    INTEGER = 0
    LONG = 1
    SINGLE = 2
    DOUBLE = 3
    STRING = 4


class Core(Elaboratable):
    STACK_N = 4
    SLOT_N = 4
    ITEM_SHAPE = 32

    def __init__(self):
        self.plat_uart = None

    def elaborate(self, platform):
        m = Module()

        m.submodules.imem = imem = Memory(shape=8, depth=len(HELLO_AVC), init=HELLO_AVC)
        imem_rd = imem.read_port()

        m.submodules.stack = self.stack = stack = Stack(width=self.ITEM_SHAPE, depth=self.STACK_N)
        m.d.sync += [
            stack.w_stream.valid.eq(0),
            stack.r_stream.ready.eq(0),
        ]

        m.submodules.slots = self.slots = slots = Memory(shape=self.ITEM_SHAPE, depth=self.SLOT_N, init=[])
        slots_rd = slots.read_port()
        slots_wr = slots.write_port()
        m.d.sync += slots_wr.en.eq(0)

        m.submodules.uart = self.uart = uart = UART(self.plat_uart)
        m.d.sync += [
            uart.wr.valid.eq(0),
            uart.rd.ready.eq(0),
        ]

        pc = Signal(range(len(HELLO_AVC) + 1))
        m.d.comb += imem_rd.addr.eq(pc)

        self.done = done = Signal()

        dslot = Signal(range(self.SLOT_N + 1))  # SLOT_N value is sentinel. kinda meh.

        op = Signal(Op)
        opa = Signal(self.ITEM_SHAPE)
        opb = Signal(self.ITEM_SHAPE)
        typ = Signal(Type)

        with m.If(~done):
            m.d.sync += Print(Format("pc={:02x} i$={:02x}", pc, imem_rd.data))

        # The memory access latency is all tied up in every op and I don't
        # really like it.
        #
        # What if we explicitly modelled imem as a stream we read from? Jumps
        # are handled by telling the stream we want to reset PC, at which point
        # it stalls until ready. We'd like something like this eventually anyway
        # when we load code from the host on-demand, and it'd simplify matters here.
        #
        # (It'd be nice for `pc` to actually be the program counter, too!)

        with m.FSM() as fsm:
            with m.State('init'):
                m.d.sync += Print(Format("{:>14s} |> stall", "init"))
                m.d.sync += pc.eq(pc + 1)
                with m.If(pc == len(HELLO_AVC)):
                    m.next = 'done'
                with m.Else():
                    m.next = 'decode'

            with m.State('done'):
                m.d.comb += done.eq(1)

            with m.State('decode'):
                m.d.sync += pc.eq(pc + 1)

                with m.Switch(imem_rd.data):
                    with m.Case(0x01): # PUSH_IMM_INTEGER
                        m.d.sync += Print(Format("{:>14s} |> PUSH_IMM_INTEGER", "decode"))
                        m.next = 'push.imm.integer'
                    with m.Case(0x0a): # PUSH_VARIABLE
                        m.d.sync += Print(Format("{:>14s} |> PUSH_VARIABLE", "decode"))
                        m.next = 'push.variable'
                    with m.Case(0x20): # LET
                        m.d.sync += Print(Format("{:>14s} |> LET", "decode"))
                        m.d.sync += dslot.eq(self.SLOT_N)
                        m.next = 'let'
                    with m.Case(0x80): # BUILTIN_PRINT
                        m.d.sync += Print(Format("{:>14s} |> BUILTIN_PRINT", "decode"))
                        m.d.sync += pc.eq(pc)
                        m.next = 'print'
                    with m.Case(0x82): # BUILTIN_PRINT_LINEFEED
                        m.d.sync += Print(Format("{:>14s} |> BUILTIN_PRINT_LINEFEED", "decode"))
                        m.d.sync += [
                            uart.wr.p.eq(ord(b'\n')),
                            uart.wr.valid.eq(1),
                        ]
                        m.next = 'decode'
                    with m.Case(0xa0): # OPERATOR_ADD_INTEGER
                        m.d.sync += Print(Format("{:>14s} |> OPERATOR_ADD_INTEGER", "decode"))
                        m.d.sync += [
                            pc.eq(pc),
                            op.eq(Op.ADD),
                            typ.eq(Type.INTEGER),
                        ]
                        m.next = 'alu'
                    with m.Case(0xa5): # OPERATOR_MULTIPLY_INTEGER
                        m.d.sync += Print(Format("{:>14s} |> OPERATOR_MULTIPLY_INTEGER", "decode"))
                        m.d.sync += [
                            pc.eq(pc),
                            op.eq(Op.MULTIPLY),
                            typ.eq(Type.INTEGER),
                        ]
                        m.next = 'alu'
                    with m.Default():
                        m.d.sync += Print(Format("{:>14s} |> ?", "decode"))
                        m.next = 'done'

            with m.State('push.imm.integer'):
                m.d.sync += Print(Format("{:>14s} |> acc", "p.i.i"))
                m.d.sync += [
                    pc.eq(pc + 1),
                    stack.w_stream.p.eq(imem_rd.data),
                ]
                m.next = 'push.imm.integer.2'

            with m.State('push.imm.integer.2'):
                d = (imem_rd.data << 8) | stack.w_stream.p[:8]
                m.d.sync += Print(Format("{:>14s} |> store v{:04x}", "p.i.i2", d))
                m.d.sync += [
                    pc.eq(pc + 1),
                    stack.w_stream.p.eq(d),
                    stack.w_stream.valid.eq(1),
                ]
                m.next = 'decode'

            with m.State('push.variable'):
                m.d.sync += Print(Format("{:>14s} |> push s{:02x}", "p.v", imem_rd.data))
                m.d.sync += [
                    slots_rd.addr.eq(imem_rd.data),
                ]
                m.next = 'push.variable.2'

            with m.State('push.variable.2'):
                m.d.sync += Print(Format("{:>14s} |> stall", "p.v2"))
                m.next = 'push.variable.3'

            with m.State('push.variable.3'):
                m.d.sync += Print(Format("{:>14s} |> v{:04x}", "p.v3", slots_rd.data))
                m.d.sync += [
                    pc.eq(pc + 1),
                    stack.w_stream.p.eq(slots_rd.data),
                    stack.w_stream.valid.eq(1),
                ]
                m.next = 'decode'

            with m.State('let'):
                with m.If(dslot == self.SLOT_N):
                    m.d.sync += dslot.eq(imem_rd.data)

                with m.If(stack.r_stream.valid):
                    slot = Mux(dslot == self.SLOT_N, imem_rd.data, dslot)
                    m.d.sync += Assert(slot < self.SLOT_N)
                    m.d.sync += Print(Format("{:>14s} |> s{:02x} <- v{:04x}", "let", dslot, stack.r_stream.p))
                    m.d.sync += [
                        pc.eq(pc + 1),
                        slots_wr.addr.eq(slot),
                        slots_wr.data.eq(stack.r_stream.p),
                        slots_wr.en.eq(1),
                        stack.r_stream.ready.eq(1),
                    ]
                    m.next = 'decode'
                with m.Else():
                    m.d.sync += Print(Format("{:>14s} |> stall", "let"))

            with m.State('print'):
                with m.If(stack.r_stream.valid):
                    m.d.sync += Print(Format("{:>14s} |> v{:04x}", "print", stack.r_stream.p))
                    m.d.sync += [
                        pc.eq(pc + 1),
                        uart.wr.payload.eq(ord(b'0') + stack.r_stream.p),
                        uart.wr.valid.eq(1),
                    ],
                    m.next = 'decode'
                with m.Else():
                    m.d.sync += Print(Format("{:>14s} |> stall", "print"))

            with m.State('alu'):
                with m.If(stack.r_stream.valid):
                    m.d.sync += Print(Format("{:>14s} |> opb <- v{:04x}", "alu", stack.r_stream.p))
                    m.d.sync += [
                        opb.eq(stack.r_stream.p),
                        stack.r_stream.ready.eq(1),
                    ]
                    m.next = 'alu2'
                with m.Else():
                    m.d.sync += Print(Format("{:>14s} |> stall", "alu"))

            with m.State('alu2'):
                m.d.sync += Print(Format("{:>14s} |> stall", "alu2"))
                m.next = 'alu3'

            with m.State('alu3'):
                with m.If(stack.r_stream.valid):
                    m.d.sync += Print(Format("{:>14s} |> opa <- v{:04x}", "alu3", stack.r_stream.p))
                    m.d.sync += [
                        opa.eq(stack.r_stream.p),
                        stack.r_stream.ready.eq(1),
                    ]
                    m.next = 'alu4'
                with m.Else():
                    m.d.sync += Print(Format("{:>14s} |> stall", "alu3"))

            with m.State('alu4'):
                m.d.sync += Print(Format("{:>14s} |> v{:04x} v{:04x} ({})", "alu4", opa, opb, op))
                m.d.sync += [
                    pc.eq(pc + 1),
                    stack.w_stream.valid.eq(1),
                ]

                m.d.sync += Assert(typ == Type.INTEGER) # XXX

                lhs = opa[:16].as_signed()
                rhs = opb[:16].as_signed()

                m.next = 'decode'
                with m.Switch(op):
                    with m.Case(Op.ADD):
                        m.d.sync += stack.w_stream.p.eq(lhs + rhs)
                    with m.Case(Op.MULTIPLY):
                        m.d.sync += stack.w_stream.p.eq(lhs * rhs)
                    with m.Case(Op.FDIVIDE):
                        m.d.sync += Assert(0) # XXX
                        m.next = 'done'
                    with m.Case(Op.IDIVIDE):
                        m.d.sync += stack.w_stream.p.eq(lhs // rhs)
                    with m.Case(Op.SUBTRACT):
                        m.d.sync += stack.w_stream.p.eq(lhs - rhs)


        return m
