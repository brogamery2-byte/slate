/*
 SPDX-License-Identifier: AGPL-3.0-or-later

 Copyright (C) 2023 - 2026 LiveContainer
 Copyright (C) 2026 emexlab

 This file is part of LiveContainer.

 LiveContainer is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 LiveContainer is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU Affero General Public License for more details.

 You should have received a copy of the GNU Affero General Public License
 along with Nyxian. If not, see <https://www.gnu.org/licenses/>.
*/

#import <LindChain/ProcEnvironment/LiveContainer/utils.h>

#define ASM(...) __asm__(#__VA_ARGS__)

// Originated from _kernelrpc_mach_vm_protect_trap
ASM(
.global _builtin_vm_protect \n
_builtin_vm_protect:     \n
    mov x16, #-0xe       \n
    svc #0x80            \n
    ret
);

void __assert_rtn(const char* func,
                  const char* file,
                  int line,
                  const char* failedexpr)
{
    [NSException raise:NSInternalInconsistencyException format:@"Assertion failed: (%s), file %s, line %d.\n", failedexpr, file, line];
    __builtin_unreachable();
}

uint64_t aarch64_emulate_adrp_ldr(uint32_t instruction,
                                  uint32_t ldrInstruction,
                                  uint64_t pc)
{
    uint32_t bad = ((instruction    & 0x9F000000u) ^ 0x90000000u)   /* is ADRP          */
                 | ((ldrInstruction & 0xFFC00000u) ^ 0xF9400000u)   /* is LDR 64        */
                 | ((instruction ^ (ldrInstruction >> 5)) & 0x1Fu); /* Rd == Rn         */
    if(bad)
    {
        return 0;
    }
    
    int64_t imm = ((int64_t)((uint64_t)instruction << 40) >> 31) & ~(int64_t)0x3FFF;
    imm |= (instruction >> 17) & 0x3000;
    uint64_t page = (pc & ~(uint64_t)0xFFF) + (uint64_t)imm;
    
    return page ? page + ((uint64_t)((ldrInstruction >> 10) & 0xFFFu) << 3) : 0;
}
