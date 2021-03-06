
# Building Dang

 - Make sure you have these tools available:
  * clang
  * llvm tools (llvm-ld, llvm-as)
  * alex
  * happy
  * ghc
   - base
   - monadLib
   - llvm-pretty (http://github.com/elliottt/llvm-pretty)
   - pretty
   - containers
   - GraphSCC
   - bytestring
   - utf8-string
   - cereal
   - containers

 - There is no install target, so just type ``make'' at the top level.  The
   resulting binary is called ``dang'' and resides in the top-level directory.


# Using Dang

  You can produce executables with dang in two ways.  The first is to compile
every module independently, and link everything together, and the second is to
build a binary that consists of just the Main module.

  To achieve the first, compile each module using the -c flag.  Make sure that
you get the order right, as dang makes no effort to figure out module order, or
compile things you've left out.  Once everything is compiled, producing .o and
.di files, you can link them and the runtime together using llvm-ld:

  $ llvm-ld -o <name> $RTS_PATH/librts.a Module_1.o [.. Module_n.o]

  If you want to just compile a single module, producing a binary, you can use
dang for the whole process.

  $ dang Main.dg

  If you would like to produce a native binary using dang, compile as normal,
producing an llvm bitcode file (something.bc), then use llc to turn it into
native assembly, and then assemble it with gcc.

  $ llc <name>.bc
  $ gcc -o <name> <name.s>
