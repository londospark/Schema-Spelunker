package sqlite3

import "core:c"
import "core:mem"
import "core:strings"

//@Incomplete - Extend this for other operating systems as we get to them.
when ODIN_OS == .Windows {
	@(private) LIB_PATH :: "sqlite3.lib"
} else {
	@(private) LIB_PATH :: "sqlite3.a"
}

when !#exists(LIB_PATH) {
	#panic("Could not find the sqlite3 lib files at \"" + LIB_PATH + "\"")
}

foreign import lib {
	LIB_PATH,
}

Database :: distinct rawptr
Statement :: distinct rawptr

CallbackStatus :: enum c.int {
	OK = 0,

	// Can be any non-zero number, will bubble up.
	ERROR = 1,
}

ExecCallback :: #type proc "c" (state: rawptr, column_count: c.int, values: [^]cstring, column_names: [^]cstring) -> CallbackStatus
Destructor :: #type proc "c" (value: rawptr)

@(default_calling_convention = "c", link_prefix="sqlite3_", require_results)
foreign lib {
	step :: proc(stmt: Statement) -> SQLiteError ---

	//@Note: The error message is a pointer to a string because sqlite mallocs, so if you don't pass NULL
	// then you MUST remember to free the cstring with free from here. Passing NULL gives no error message.
	exec :: proc(db: Database, sql: cstring, callback: ExecCallback, state: rawptr, error_message: ^cstring) -> SQLiteError ---

	// Returns a pointer that is only valid until the next sqlite call,
	// get a clone if you would like something longer lived.
	column_text :: proc(stmt: Statement, column: c.int) -> cstring ---
	column_int :: proc(stmt: Statement, column: c.int) -> c.int ---
}

@(default_calling_convention = "c", link_prefix="sqlite3_")
foreign lib {
	free :: proc(memory: rawptr) ---
	finalize :: proc(stmt: Statement) -> SQLiteError ---
	close :: proc(db: Database) -> SQLiteError ---
}

@(require_results)
column_string :: proc(stmt: Statement, column: c.int, allocator: mem.Allocator=context.allocator) -> string {
	cs := column_text(stmt, column)
	return strings.clone(string(cs), allocator)
}

@(require_results)
column_bool :: proc "c" (stmt: Statement, column: c.int) -> bool {
	return column_int(stmt, column) != 0
}

@(require_results)
column_u32 :: proc "c" (stmt: Statement, column: c.int) -> u32 {
	return u32(column_int(stmt, column))
}

@(require_results)
bind_text :: proc "c" (stmt: Statement, index: i32, value: cstring) -> SQLiteError {
	foreign lib {
		sqlite3_bind_text :: proc(stmt : Statement, index: c.int, value: cstring, bytes: c.int, destructor: Destructor) -> SQLiteError ---
	}
	return sqlite3_bind_text(stmt, (c.int)(index), value, (c.int)(len(value)), nil)
}

@(require_results)
open :: proc "c" (filename: cstring) -> (Database, SQLiteError) {
	foreign lib {
		sqlite3_open :: proc(filename: cstring, ppDb: ^Database) -> SQLiteError ---
	}
	db: Database
	error := sqlite3_open(filename, &db)
	return db, error
}

prepare :: proc "c" (db: Database, sql: cstring) -> (Statement, SQLiteError) {
	foreign lib {
		sqlite3_prepare_v2 :: proc "c" (db: Database, sql: cstring, count: c.int, stmt: ^Statement, tail: ^cstring) -> SQLiteError ---
	}
	stmt: Statement
	// The docs say that you get a little speed up if you give the string length WITH
	// the null terminator. We can, so we will.
	error := sqlite3_prepare_v2(db, sql, c.int(len(sql) + 1), &stmt, nil)
	return stmt, error
}

SQLiteError :: enum c.int {
	// Primary Result Codes
	ABORT      = 4,
	AUTH       = 23,
	BUSY       = 5,
	CANTOPEN   = 14,
	CONSTRAINT = 19,
	CORRUPT    = 11,
	DONE       = 101,
	EMPTY      = 16,
	ERROR      = 1,
	FORMAT     = 24,
	FULL       = 13,
	INTERNAL   = 2,
	INTERRUPT  = 9,
	IOERR      = 10,
	LOCKED     = 6,
	MISMATCH   = 20,
	MISUSE     = 21,
	NOLFS      = 22,
	NOMEM      = 7,
	NOTADB     = 26,
	NOTFOUND   = 12,
	NOTICE     = 27,
	OK         = 0,
	PERM       = 3,
	PROTOCOL   = 15,
	RANGE      = 25,
	READONLY   = 8,
	ROW        = 100,
	SCHEMA     = 17,
	TOOBIG     = 18,
	WARNING    = 28,

	// Extended Result Codes
	ABORT_ROLLBACK          = 516,
	AUTH_USER               = 279,
	BUSY_RECOVERY           = 261,
	BUSY_SNAPSHOT           = 517,
	BUSY_TIMEOUT            = 773,
	CANTOPEN_CONVPATH       = 1038,
	CANTOPEN_DIRTYWAL       = 1294,
	CANTOPEN_FULLPATH       = 782,
	CANTOPEN_ISDIR          = 526,
	CANTOPEN_NOTEMPDIR      = 270,
	CANTOPEN_SYMLINK        = 1550,
	CONSTRAINT_CHECK        = 275,
	CONSTRAINT_COMMITHOOK   = 531,
	CONSTRAINT_DATATYPE     = 3091,
	CONSTRAINT_FOREIGNKEY   = 787,
	CONSTRAINT_FUNCTION     = 1043,
	CONSTRAINT_NOTNULL      = 1299,
	CONSTRAINT_PINNED       = 2835,
	CONSTRAINT_PRIMARYKEY   = 1555,
	CONSTRAINT_ROWID        = 2579,
	CONSTRAINT_TRIGGER      = 1811,
	CONSTRAINT_UNIQUE       = 2067,
	CONSTRAINT_VTAB         = 2323,
	CORRUPT_INDEX           = 779,
	CORRUPT_SEQUENCE        = 523,
	CORRUPT_VTAB            = 267,
	ERROR_MISSING_COLLSEQ   = 257,
	ERROR_RETRY             = 513,
	ERROR_SNAPSHOT          = 769,
	IOERR_ACCESS            = 3338,
	IOERR_AUTH              = 7178,
	IOERR_BEGIN_ATOMIC      = 7434,
	IOERR_BLOCKED           = 2826,
	IOERR_CHECKRESERVEDLOCK = 3594,
	IOERR_CLOSE             = 4106,
	IOERR_COMMIT_ATOMIC     = 7690,
	IOERR_CONVPATH          = 6666,
	IOERR_CORRUPTFS         = 8458,
	IOERR_DATA              = 8202,
	IOERR_DELETE            = 2570,
	IOERR_DELETE_NOENT      = 5898,
	IOERR_DIR_CLOSE         = 4362,
	IOERR_DIR_FSYNC         = 1290,
	IOERR_FSTAT             = 1802,
	IOERR_FSYNC             = 1034,
	IOERR_GETTEMPPATH       = 6410,
	IOERR_LOCK              = 3850,
	IOERR_MMAP              = 6154,
	IOERR_NOMEM             = 3082,
	IOERR_RDLOCK            = 2314,
	IOERR_READ              = 266,
	IOERR_ROLLBACK_ATOMIC   = 7946,
	IOERR_SEEK              = 5642,
	IOERR_SHMLOCK           = 5130,
	IOERR_SHMMAP            = 5386,
	IOERR_SHMOPEN           = 4618,
	IOERR_SHMSIZE           = 4874,
	IOERR_SHORT_READ        = 522,
	IOERR_TRUNCATE          = 1546,
	IOERR_UNLOCK            = 2058,
	IOERR_VNODE             = 6922,
	IOERR_WRITE             = 778,
	LOCKED_SHAREDCACHE      = 262,
	LOCKED_VTAB             = 518,
	NOTICE_RECOVER_ROLLBACK = 539,
	NOTICE_RECOVER_WAL      = 283,
	OK_LOAD_PERMANENTLY     = 256,
	READONLY_CANTINIT       = 1288,
	READONLY_CANTLOCK       = 520,
	READONLY_DBMOVED        = 1032,
	READONLY_DIRECTORY      = 1544,
	READONLY_RECOVERY       = 264,
	READONLY_ROLLBACK       = 776,
	WARNING_AUTOINDEX       = 284,
}
