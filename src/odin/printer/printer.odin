package odin_printer

import "core:fmt"
import "core:log"
import "core:mem"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:slice"
import "core:strings"

Printer :: struct {
	string_builder:       strings.Builder,
	config:               Config,
	comments:             [dynamic]^ast.Comment_Group,
	comments_option:      map[int]Line_Suffix_Option,
	latest_comment_index: int,
	allocator:            mem.Allocator,
	file:                 ^ast.File,
	source_position:      tokenizer.Pos,
	last_source_position: tokenizer.Pos,
	skip_semicolon:       bool,
	current_line_index:   int,
	last_line_index:      int,
	document:             ^Document,
	indentation:          string,
	newline:              string,
	indentation_width:    int,
	disabled_lines:       map[int]Disabled_Info,
	disabled_until_line:  int,
	lines_with_ignore:    [dynamic]Disabled_Info,
	group_modes:          map[string]Document_Group_Mode,
	force_statement_fit:  bool,
	src:                  string,
}

Disabled_Info :: struct {
	text:       string,
	empty:      bool,
	start_line: int,
	end_line:   int,
}

Config :: struct {
	character_width: int,
	spaces:          int, //Spaces per indentation
	newline_limit:   int, //The limit of newlines between statements and declarations.
	tabs:            bool, //Enable or disable tabs
	tabs_width:      int,
	convert_do:      bool, //Convert all do statements to brace blocks
	brace_style:     Brace_Style,
	indent_cases:    bool,
	newline_style:   Newline_Style,
	sort_imports:    bool,
}

Brace_Style :: enum {
	_1TBS,
	Allman,
	Stroustrup,
	K_And_R,
}

Block_Type :: enum {
	None,
	If_Stmt,
	Proc,
	Generic,
	Comp_Lit,
	Switch_Stmt,
}

Expr_Called_Type :: enum {
	Generic,
	Value_Decl,
	Assignment_Stmt,
	Call_Expr,
	Binary_Expr,
}

Newline_Style :: enum {
	CRLF,
	LF,
}

Line_Suffix_Option :: enum {
	Default,
	Indent,
}


when ODIN_OS == .Windows {
	default_style := Config {
		spaces          = 4,
		newline_limit   = 2,
		convert_do      = false,
		tabs            = true,
		tabs_width      = 4,
		brace_style     = ._1TBS,
		indent_cases    = false,
		newline_style   = .CRLF,
		character_width = 100,
		sort_imports    = true,
	}
} else {
	default_style := Config {
		spaces          = 4,
		newline_limit   = 2,
		convert_do      = false,
		tabs            = true,
		tabs_width      = 4,
		brace_style     = ._1TBS,
		indent_cases    = false,
		newline_style   = .LF,
		character_width = 100,
		sort_imports    = true,
	}
}

make_printer :: proc(config: Config, allocator := context.allocator) -> Printer {
	return {config = config, allocator = allocator}
}


@(private)
build_disabled_lines_info :: proc(p: ^Printer) {
	found_disable := false
	disable_position: tokenizer.Pos
	empty := true

	for group in p.comments {
		for comment in group.list {
			comment_text, _ := strings.replace_all(comment.text[:], " ", "", context.temp_allocator)
			fmt_rule := strings.trim_prefix(comment_text, "//odinfmt:")

			switch {
			case strings.compare(fmt_rule, "ignore") == 0:
				append(&p.lines_with_ignore, Disabled_Info{start_line = comment.pos.line})

			case strings.compare(fmt_rule, "disable") == 0:
				found_disable = true
				empty = true
				disable_position = comment.pos

			case strings.compare(fmt_rule, "enable") == 0 && found_disable:
				begin := disable_position.offset - (comment.pos.column - 1)
				end := comment.pos.offset + len(comment.text)
				disabled_info := Disabled_Info {
					start_line = disable_position.line,
					end_line   = comment.pos.line,
					text       = p.src[begin:end],
					empty      = empty,
				}

				for line := disable_position.line; line <= comment.pos.line; line += 1 {
					p.disabled_lines[line] = disabled_info
				}

				found_disable = false
			}
		}
		empty = false
	}
}

@(private)
set_comment_option :: proc(p: ^Printer, line: int, option: Line_Suffix_Option) {
	p.comments_option[line] = option
}

print :: proc {
	print_file,
	print_expr,
}

print_expr :: proc(p: ^Printer, expr: ^ast.Expr) -> string {
	p.document = empty()
	p.document = cons(p.document, visit_expr(p, expr))
	p.string_builder = strings.builder_make(p.allocator)
	context.allocator = p.allocator

	list := make([dynamic]Tuple, p.allocator)

	append(&list, Tuple{document = p.document, indentation = 0})

	format(p.config.character_width, &list, &p.string_builder, p)

	return strings.to_string(p.string_builder)
}


@(private)
traverse_ignoring_stmts :: proc(p: ^Printer, file: ^ast.File) {
	for decl, i in file.decls {
		decl := cast(^ast.Decl)decl

		for &disabled in p.lines_with_ignore {
			// try attach to next stmt
			if disabled.start_line < decl.pos.line {
				start_line := decl.pos.line
				end_line := decl.end.line

				offset_start := decl.pos.offset
				offset_end := decl.end.offset - 1

				disabled_info := Disabled_Info {
					start_line = start_line,
					end_line   = end_line,
					text       = p.src[offset_start:offset_end],
				}

				p.disabled_lines[start_line] = disabled_info

				ordered_remove(&p.lines_with_ignore, 0)
				break
			}
		}
	}
}

print_file :: proc(p: ^Printer, file: ^ast.File) -> string {
	p.comments = file.comments
	p.string_builder = strings.builder_make(0, len(file.src) * 2, p.allocator)
	p.src = file.src
	context.allocator = p.allocator

	if p.config.tabs {
		p.indentation = "\t"
		p.indentation_width = p.config.tabs_width
	} else {
		p.indentation = strings.repeat(" ", p.config.spaces)
		p.indentation_width = p.config.spaces
	}

	if p.config.newline_style == .CRLF {
		p.newline = "\r\n"
	} else {
		p.newline = "\n"
	}

	build_disabled_lines_info(p)
	traverse_ignoring_stmts(p, file)

	p.source_position.line = 1
	p.source_position.column = 1

	p.document = move_line(p, file.pkg_token.pos)
	p.document = cons(p.document, cons_with_nopl(text(file.pkg_token.text), text(file.pkg_name)))

	// Keep track of the first import in a row, to sort them later.
	import_group_start: Maybe(int)

	for decl, i in file.decls {
		decl := cast(^ast.Decl)decl

		if imp, is_import := decl.derived.(^ast.Import_Decl); p.config.sort_imports && is_import {
			// First import in this group.
			if import_group_start == nil {
				import_group_start = i
				continue
			}

			// If this import is on the next line, it is part of the group.
			if imp.pos.line - 1 == file.decls[i - 1].end.line {
				continue
			}

			// This is an import, but it is separated, lets sort the current group.
			print_sorted_imports(p, file.decls[import_group_start.?:i])
			import_group_start = i
		} else {
			// If there were imports before this declaration, sort and print them.
			if import_group_start != nil {
				print_sorted_imports(p, file.decls[import_group_start.?:i])
				import_group_start = nil
			}

			p.document = cons(p.document, visit_decl(p, decl))
		}
	}

	if len(p.comments) > 0 {
		infinite := p.comments[len(p.comments) - 1].end
		infinite.offset = 9999999
		document, _ := visit_comments(p, infinite)
		p.document = cons(p.document, document)
	}

	p.document = cons(p.document, newline(1))

	list := make([dynamic]Tuple, p.allocator)

	append(&list, Tuple{document = p.document, indentation = 0})

	format(p.config.character_width, &list, &p.string_builder, p)

	return strings.to_string(p.string_builder)
}

// Sort the imports and add them to the document.
@(private)
print_sorted_imports :: proc(p: ^Printer, decls: []^ast.Stmt) {
	start_line := decls[0].pos.line

	slice.stable_sort_by(decls, proc(imp1, imp2: ^ast.Stmt) -> bool {
		return imp1.derived.(^ast.Import_Decl).fullpath < imp2.derived.(^ast.Import_Decl).fullpath
	})

	for decl, i in decls {
		decl.pos.line = start_line + i
		decl.end.line = start_line + i

		p.document = cons(p.document, visit_decl(p, cast(^ast.Decl)decl))
	}
}
