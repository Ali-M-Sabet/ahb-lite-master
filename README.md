# AHB-Lite Master

A SystemVerilog master for aligned 32-bit transfers, with a two-slave interconnect and a self-checking testbench. The bus follows the subset of [Arm IHI 0033A](https://developer.arm.com/documentation/ihi0033/a) described below.

## Project files

| File | What it does |
| --- | --- |
| [AHB_master.sv](AHB_master.sv) | Accepts requests, drives address and write data, and reports each beat's result. |
| [AHB_interconnect.sv](AHB_interconnect.sv) | Decodes two address ranges and routes the data-phase response. |
| [tb_master_interconnect.sv](tb_master_interconnect.sv) | Drives both mock slave responses and checks the master and interconnect together. |
| [run.do](run.do) | Compiles and runs the testbench in QuestaSim. |

## Supported features

| Feature | Behavior |
| --- | --- |
| Reads and writes | One 32-bit word per beat. Start addresses must be four-byte aligned. |
| SINGLE | One NONSEQ beat. Independent requests can be pipelined. |
| INCR | Starts with NONSEQ, then uses SEQ for each continuation. The address advances by four bytes and the direction stays fixed. |
| Wait states | Holds an active address and its control during ordinary waits. Write data stays stable until the data phase completes. |
| BUSY | Pauses an open INCR burst before the next beat. |
| 1 KB boundary | Ends the burst before it crosses into the next 1 KB region. |
| ERROR | Handles the two-cycle bus response and cancels a pending following address. |

Outside the scope are byte, halfword, wider and unaligned transfers, fixed-length and wrapping bursts, and locked transfers. HMASTLOCK is low and HPROT is fixed at 4'b0011.

## Architecture

~~~mermaid
flowchart LR
    R[Requester] <-->|Requests and results| M[AHB-Lite master]
    M <-->|Address, control, data and response| I[Interconnect]
    I <-->|Slave 0| S0[Mock slave 0]
    I <-->|Slave 1| S1[Mock slave 1]
~~~

| Address range | Target |
| --- | --- |
| `0x0000_0000–0x0000_0FFF` | Slave 0 |
| `0x0000_1000–0x0000_1FFF` | Slave 1 |
| Other addresses | Default response logic returns a two-cycle `ERROR` for an active transfer. |

### Address and data phases

1. The requester submits a single read at `0x0000_1000`. On the request handshake, the master captures the address and presents it as `NONSEQ`.
2. The interconnect asserts `HSEL1`. When `HREADY=1` at a rising edge, it saves slave 1 as the owner of the data phase. The next address can select slave 0 while slave 1 still owns the response.
3. When slave 1 completes with `HREADY=1` and `HRESP=0`, the master captures `HRDATA` and presents it with `rsp_valid` and `data_r_valid`.

For writes, the master saves `data_w` at the request handshake and drives it on `HWDATA` during that beat's data phase. A slave wait keeps that write word on the bus until the beat completes.

### Requester signals

| Signal | Direction | Meaning |
| --- | --- | --- |
| `send`, `master_ready` | In, out | A rising edge with both high accepts one beat. |
| `continue_burst` | In | `0` starts a transfer or burst. `1` supplies the next beat of an open `INCR`. |
| `addr`, `wr_en`, `size`, `burst` | In | Start address, direction, word size (`3'b010`), and burst type (`000` for `SINGLE`, `001` for `INCR`). Continuations inherit direction and size and use the next burst address. |
| `data_w` | In | Write data for the requested beat. |
| `sender_busy` | In | Use `sender_busy=1` and `send=0` to pause an open `INCR`. Clear both to end it. |
| `boundary_reached` | Out | Pulses when the bus accepts the final address of the current 1 KB region in an `INCR` burst. |
| `rsp_valid`, `rsp_status` | Out | Result for one accepted beat. |
| `data_r_valid`, `data_r` | Out | Data for a successful read. |

Hold a pending request stable until acceptance. After a boundary pulse, replace a held continuation with an explicit start if more transfers are needed. Reset clears outstanding requests.

| rsp_status | Meaning |
| --- | --- |
| 00 OKAY | The bus beat completed successfully. |
| 01 BUS_ERROR | The bus beat completed with ERROR. |
| 10 CANCELED | The master accepted the beat from the requester, then canceled its address after an earlier beat failed. |
| 11 INVALID_REQUEST | The burst type, size, or alignment of a new start was invalid. No bus beat was issued. |

The requester samples each result on a rising edge with `rsp_valid=1`. On the first cycle of a bus error, `HRESP=1` and `HREADY=0`. The master drives `IDLE` for the second cycle so a pending address is canceled before the slave can accept it. When `HREADY` goes high, the master reports `BUS_ERROR` for the failing beat, then reports `CANCELED` on the next response cycle if it had accepted a following beat.

## State machine

HTRANS follows the current state. The FSM describes the address phase, so a beat can still be in its data phase while the FSM is IDLE.

~~~mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> NONSEQ: Accept a valid start
    NONSEQ --> NONSEQ: SINGLE advances and next start is accepted
    NONSEQ --> SEQ: INCR continuation accepted
    NONSEQ --> BUSY: INCR pauses
    NONSEQ --> IDLE: SINGLE has no next start or INCR ends
    SEQ --> SEQ: Accept next beat
    SEQ --> BUSY: INCR pauses
    SEQ --> IDLE: INCR ends
    BUSY --> BUSY: Pause continues
    BUSY --> SEQ: Accept continuation
    BUSY --> IDLE: End burst
~~~

Reset and bus errors take the FSM to IDLE. During an ordinary wait, NONSEQ and SEQ hold. IDLE can accept a new start, and BUSY can resume at the address it already presents.

An INCR burst starting at 0x3F8 can continue at 0x3FC. When the bus accepts the address at 0x3FC, boundary_reached pulses and the master ends the burst. Any held continuation stays unaccepted. An explicit start may reuse 0x3F8 or supply a different aligned address.

## Run the testbench

From the project folder, run this command with QuestaSim on your PATH.

~~~text
vsim -c -do run.do
~~~

The script creates the simulator library if needed, compiles the three source files, and runs the testbench. It returns a nonzero exit code if the testbench fails to reach its pass check.

A passing run prints `INTEGRATION_PASS`. The ordered scoreboard checks the status, read-valid flag, and read data for all **19 accepted requests**.

| Scenario | What the test checks |
| --- | --- |
| Reset and single transfers | Idle bus after reset, slave selection, write data, and returned read data. |
| Wait states and pipelining | Address and write data hold during a stall. Back-to-back reads route each response to the correct beat even when the next address selects the other slave. |
| Incrementing bursts | Four-byte address steps, distinct write data per beat, and a pause and resume through `BUSY`. |
| 1 KB boundary | A held continuation stays unaccepted. An explicit start can reuse the original address. |
| Invalid requests and errors | Invalid burst, size, and alignment are rejected locally. Unmapped and slave errors are reported, including a case that returns `BUS_ERROR` followed by `CANCELED`. |

## Project background

This project began as a digital design assignment during my summer internship at Analog Devices.
