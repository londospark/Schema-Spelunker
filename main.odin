package main

import "core:fmt"
import "core:c"

// --- SQLITE3 BINDINGS ---

//@Incomplete - Extend this for other operating systems as we get to them.
when ODIN_OS == .Windows {
	@(private) LIB_PATH :: "lib/sqlite3.lib"
} else {
	@(private) LIB_PATH :: "lib/sqlite3_other.a"
}

when !#exists(LIB_PATH) {
	#panic("Could not find the sqlite3 lib files at \"" + LIB_PATH + "\"")
}

foreign import lib {
	LIB_PATH,
}

Database :: distinct rawptr

@(default_calling_convention = "c", link_prefix="sqlite3_")
foreign lib {
	close :: proc(db: Database) -> c.int ---
}

open :: proc "c" (filename: cstring) -> (Database, c.int) {
	foreign lib {
		sqlite3_open  :: proc(filename: cstring, ppDb: ^Database) -> c.int ---
	}
	db: Database
	error := sqlite3_open(filename, &db)
	return db, error
}

// --- PROGRAM CODE ---

main :: proc() {
	fmt.println("Hellope!")
	db, error := open("something.db")
	fmt.printfln("Call returned: %d", error)
	error = close(db)
	fmt.printfln("Close returned %d", error)
}