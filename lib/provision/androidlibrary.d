module provision.androidlibrary;

import core.exception;
import core.memory;
import core.stdc.stdint;
import core.sys.linux.elf;
import core.sys.linux.link;
import core.sys.posix.sys.mman;
import std.algorithm;
import std.conv;
import std.experimental.allocator;
import std.experimental.allocator.mallocator;
import std.experimental.allocator.mmap_allocator;
import std.mmfile;
import std.path;
import std.random;
import std.range;
import std.stdio;
import std.string;
import std.traits;

public struct AndroidLibrary {
    package MmFile elfFile;
    package void[] allocation;

    package char[] sectionNamesTable;
    package char[] dynamicStringTable;
    package ElfW!"Sym"[] dynamicSymbolTable;
    package GnuHashTable* gnuHashTable;

    public this(string libraryName) {
        elfFile = new MmFile(libraryName);

        auto elfHeader = elfFile.identify!(ElfW!"Ehdr")(0);
        auto programHeaders = elfFile.identifyArray!(ElfW!"Phdr")(elfHeader.e_phoff, elfHeader.e_phnum);

        size_t minimum = size_t.max;
        size_t maximumFile = size_t.min;
        size_t maximumMemory = size_t.min;

        size_t headerStart;
        size_t headerEnd;
        size_t headerMemoryEnd;

        foreach (programHeader; programHeaders) {
            if (programHeader.p_type == PT_LOAD) {
                headerStart = programHeader.p_vaddr;
                headerEnd = programHeader.p_vaddr + programHeader.p_filesz;
                headerMemoryEnd = programHeader.p_vaddr + programHeader.p_memsz;

                if (headerStart < minimum) {
                    minimum = headerStart;
                }
                if (headerEnd > maximumFile) {
                    maximumFile = headerEnd;
                }
                if (headerMemoryEnd > maximumMemory) {
                    maximumMemory = headerMemoryEnd;
                }
            }
        }

        auto alignedMinimum = pageFloor(minimum);
        auto alignedMaximumMemory = pageCeil(maximumMemory);

        auto allocSize = alignedMaximumMemory - alignedMinimum;
        allocation = MmapAllocator.instance.allocate(allocSize)[0..allocSize];
        writefln!("Allocated %1$d bytes (%1$x) of memory, at %2$x")(allocSize, allocation.ptr);

        foreach (programHeader; programHeaders) {
            if (programHeader.p_type == PT_LOAD) {
                headerStart = programHeader.p_vaddr;
                headerEnd = programHeader.p_vaddr + programHeader.p_filesz;
                allocation[headerStart - alignedMinimum..headerEnd - alignedMinimum] = elfFile[headerStart..headerEnd];

                mprotect(allocation.ptr + headerStart, headerEnd - headerStart, programHeader.memoryProtection());
            }
        }

        auto sectionHeaders = elfFile.identifyArray!(ElfW!"Shdr")(elfHeader.e_shoff, elfHeader.e_shnum);
        auto sectionStrTable = sectionHeaders[elfHeader.e_shstrndx];
        sectionNamesTable = cast(char[]) elfFile[sectionStrTable.sh_offset..sectionStrTable.sh_offset + sectionStrTable.sh_size];

        foreach (sectionHeader; sectionHeaders) {
            switch (sectionHeader.sh_type) {
                case SHT_DYNSYM:
                    dynamicSymbolTable = elfFile.identifyArray!(ElfW!"Sym")(sectionHeader.sh_offset, sectionHeader.sh_size / ElfW!"Sym".sizeof);
                    break;
                case SHT_STRTAB:
                    if (getSectionName(sectionHeader) == ".dynstr")
                        dynamicStringTable = cast(char[]) elfFile[sectionHeader.sh_offset..sectionHeader.sh_offset + sectionHeader.sh_size];
                    break;
                case SHT_GNU_HASH:
                    gnuHashTable = new GnuHashTable(cast(ubyte[]) elfFile[sectionHeader.sh_offset..sectionHeader.sh_offset + sectionHeader.sh_size]);
                    break;
                case SHT_REL:
                    this.relocate!(ElfW!"Rel")(sectionHeader);
                    break;
                case SHT_RELA:
                    this.relocate!(ElfW!"Rela")(sectionHeader);
                    break;
                default:
                    break;
            }
        }
    }

    private void relocate(RelocationType)(ref ElfW!"Shdr" shdr) {
        auto relocations = this.elfFile.identifyArray!(RelocationType)(shdr.sh_offset, shdr.sh_size / RelocationType.sizeof);
        auto allocation = cast(ubyte[]) allocation;

        foreach (relocation; relocations) {
            auto relocationType = ELFW!"R_TYPE"(relocation.r_info);
            auto symbolIndex = ELFW!"R_SYM"(relocation.r_info);

            auto offset = relocation.r_offset;
            size_t addend;
            static if (__traits(hasMember, relocation, "r_addend")) {
                addend = relocation.r_addend;
            } else {
                if (relocationType == R_GENERIC_NATIVE_ABS) {
                    addend = 0;
                } else {
                    addend = *cast(size_t*) (allocation.ptr + offset);
                }
            }
            auto symbol = getSymbolImplementation(getSymbolName(dynamicSymbolTable[symbolIndex]));

            auto location = cast(size_t*) (cast(size_t) allocation.ptr + offset);

            switch (relocationType) {
                case R_GENERIC!"RELATIVE":
                    *location = cast(size_t) (allocation.ptr + addend);
                    break;
                case R_GENERIC!"GLOB_DAT":
                case R_GENERIC!"JUMP_SLOT":
                    *location = cast(size_t) (symbol + addend);
                    break;
                case R_GENERIC_NATIVE_ABS:
                    *location = cast(size_t) (symbol + addend);
                    break;
                default:
                    throw new LoaderException("Unknown relocation type: " ~ to!string(relocationType));
            }
        }
    }

    private string getSymbolName(ElfW!"Sym" symbol) {
        return cast(string) fromStringz(&dynamicStringTable[symbol.st_name]);
    }

    private string getSectionName(ElfW!"Shdr" section) {
        return cast(string) fromStringz(&sectionNamesTable[section.sh_name]);
    }

    void* load(string symbolName) {
        return gnuHashTable.lookup(symbolName, this);
    }
}

package struct GnuHashTable {
    struct GnuHashTableStruct {
        uint nbuckets;
        uint symoffset;
        uint bloomSize;
        uint bloomShift;
    }

    GnuHashTableStruct table;
    ulong[] bloom;
    uint[] buckets;
    uint[] chain;

    this(ubyte[] tableData) {
        table = *cast(GnuHashTableStruct*) tableData.ptr;
        auto bucketsLocation = GnuHashTableStruct.sizeof + table.bloomSize * (ulong.sizeof / ubyte.sizeof);
        auto chainLocation = bucketsLocation + table.nbuckets * (uint.sizeof / ubyte.sizeof);

        bloom = cast(ulong[]) tableData[GnuHashTableStruct.sizeof..bucketsLocation];
        buckets = cast(uint[]) tableData[bucketsLocation..chainLocation];
        chain = cast(uint[]) tableData[chainLocation..$];
    }

    static uint hash(string name) {
        uint32_t h = 5381;

        foreach (c; name) {
            h = (h << 5) + h + c;
        }

        return h;
    }

    void* lookup(string symbolName, AndroidLibrary library) {
        auto targetHash = hash(symbolName);
        auto bucket = buckets[targetHash % table.nbuckets];

        if (bucket < table.symoffset) {
            throw new LoaderException("Symbol not found: " ~ symbolName);
        }

        auto chain_index = bucket - table.symoffset;
        targetHash &= ~1;
        auto chains = chain[chain_index..$];
        auto dynsyms = library.dynamicSymbolTable[bucket..$];
        foreach (hash, symbol; zip(chains, dynsyms)) {
            if ((hash &~ 1) == targetHash && symbolName == library.getSymbolName(symbol)) {
                return cast(void*) (cast(size_t) library.allocation.ptr + symbol.st_value);
            }

            if (hash & 1) {
                break;
            }
        }

        throw new LoaderException("Symbol not found: " ~ symbolName);
    }
}

private size_t pageMask;

shared static this()
{
    pageMask = ~(pageSize - 1);
}

int memoryProtection(ref ElfW!"Phdr" phdr)
{
    int prot = 0;
    if (phdr.p_flags & PF_R)
        prot |= PROT_READ;
    if (phdr.p_flags & PF_W)
        prot |= PROT_WRITE;
    if (phdr.p_flags & PF_X)
        prot |= PROT_EXEC;

    return prot;
}

template ELFW(string func) {
    alias ELFW = mixin("ELF" ~ to!string(size_t.sizeof * 8) ~ "_" ~ func);
}

version (X86_64) {
    private enum string relocationArch = "X86_64";
    private enum R_GENERIC_NATIVE_ABS = R_X86_64_64;
} else version (X86) {
    private enum string relocationArch = "386";
    private enum R_GENERIC_NATIVE_ABS = R_386_32;
} else version (AArch64) {
    private enum string relocationArch = "AARCH64";
    private enum R_GENERIC_NATIVE_ABS = R_AARCH64_ABS64;
} else version (ARM) {
    private enum string relocationArch = "ARM";
    private enum R_GENERIC_NATIVE_ABS = R_ARM_ABS32;
}

template R_GENERIC(string relocationType) {
    enum R_GENERIC = mixin("R_" ~ relocationArch ~ "_" ~ relocationType);
}

size_t pageFloor(size_t number) {
    return number & pageMask;
}

size_t pageCeil(size_t number) {
    return (number + pageSize - 1) & pageMask;
}

RetType[] identifyArray(RetType, FromType)(FromType obj, size_t offset, size_t length) {
    return (cast(RetType[]) obj[offset..offset + (RetType.sizeof * length)]).ptr[0..length];
}

RetType identify(RetType, FromType)(FromType obj, size_t offset) {
    return obj[offset..offset + RetType.sizeof].reinterpret!(RetType);
}

RetType reinterpret(RetType, FromType)(FromType[] obj) {
    return (cast(RetType[]) obj)[0];
}

private static void* getSymbolImplementation(string symbolName) {
    import provision.symbols;
    auto symbol = in_word_set(symbolName);

    if (symbol) return symbol;

    return &undefinedSymbol;
}

class LoaderException: Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) {
        super("Cannot load library: " ~ message, file, line);
    }
}

class UndefinedSymbolException: Exception {
    this(string file = __FILE__, size_t line = __LINE__) {
        super("An undefined symbol has been called!", file, line);
    }
}
