using Gee;

class Parser {
	Scanner scanner;
	
	Token peek_token() { return scanner.peek_token(); }
	Token next_token() { return scanner.next_token(); }
	
	bool accept(Token t) {
		if (peek_token() == t) {
			next_token();
			return true;
		}
		return false;
	}
	
	bool skip_to(Token t) {
		while (!scanner.eof())
			if (next_token() == t)
				return true;
		return false;
	}
	
	// Skip to a right brace or semicolon.
	void skip() {
		int depth = 0;
		while (true)
			switch (next_token()) {
				case Token.EOF:
					return;
				case Token.LEFT_BRACE:
					++depth;
					break;
				case Token.RIGHT_BRACE:
					if (--depth <= 0) {
						accept(Token.SEMICOLON);
						return;
					}
					break;
				case Token.SEMICOLON:
					if (depth == 0)
						return;
					break;
			}
	}
	
	CompoundName? parse_type() {
		if (!accept(Token.ID))
			return null;
		CompoundName t = new SimpleName(scanner.val());
		while (accept(Token.PERIOD)) {
			if (!accept(Token.ID))
				return null;
			t = new QualifiedName(t, scanner.val());
		}
		if (accept(Token.LESS_THAN)) {	// parameterized type
			if (parse_type() == null)
				return null;
			while (!accept(Token.GREATER_THAN)) {
				if (!accept(Token.COMMA) || parse_type() == null)
					return null;
			}
		}
		do {
			if (accept(Token.QUESTION_MARK) || accept(Token.ASTERISK))
				continue;
			if (accept(Token.LEFT_BRACKET)) {
				accept(Token.RIGHT_BRACKET);
				continue;
			}
		} while (false);
		return t;
	}
	
	// Skip an expression, looking for a following comma, right parenthesis,
	// semicolon or right brace.
	void skip_expression() {
		int depth = 0;
		while (!scanner.eof()) {
			switch (peek_token()) {
				case Token.COMMA:
				case Token.RIGHT_BRACE:
				case Token.SEMICOLON:
					if (depth == 0)
						return;
					break;
				case Token.LEFT_PAREN:
					++depth;
					break;
				case Token.RIGHT_PAREN:
					if (depth == 0)
						return;
					--depth;
					break;
			}
			next_token();
		}
	}
	
	Parameter? parse_parameter() {
		Token t = peek_token();
		if (t == Token.OUT || t == Token.REF)
			next_token();
		CompoundName type = parse_type();
		if (type == null || !accept(Token.ID))
			return null;
		Parameter p = new Parameter(type, scanner.val(), scanner.start, scanner.end);
		if (accept(Token.EQUALS))
			skip_expression();
		return p;
	}
	
	ForEach? parse_foreach() {
		int start = scanner.start;
		if (!accept(Token.LEFT_PAREN))
			return null;
		CompoundName type = parse_type();
		if (type == null || !accept(Token.ID)) {
			skip();
			return null;
		}
		LocalVariable v = new LocalVariable(type, scanner.val(), scanner.start, scanner.end);
		skip_expression();
		if (!accept(Token.RIGHT_PAREN)) {
			skip();
			return null;
		}
		Statement s = parse_statement();
		return new ForEach(v, s, start, scanner.end);
	}
	
	Statement? parse_statement() {
		if (accept(Token.FOREACH))
			return parse_foreach();
			
		CompoundName type = parse_type();
		if (type != null && accept(Token.ID)) {
			string name = scanner.val();
			int start = scanner.start;
			LocalVariable v = new LocalVariable(type, name, start, scanner.end);
			Token token = peek_token();
			if (token == Token.SEMICOLON || token == Token.EQUALS) {
				skip();
				return new DeclarationStatement(v, start, scanner.end);
			}
		}
		
		// We found no declaration.  Scan through the remainder of the
		// statement, looking for an embedded block.
		while (true)
			switch (next_token()) {
				case Token.EOF:
				case Token.RIGHT_BRACE:
				case Token.SEMICOLON:
					return null;
				case Token.LEFT_BRACE:
					return parse_block();
			}
	}

	// Parse a block after the opening brace.	
	Block? parse_block() {
		Block b = new Block();
		b.start = scanner.start;
		while (!scanner.eof() && !accept(Token.RIGHT_BRACE)) {
			Statement s = parse_statement();
			if (s != null)
				b.statements.add(s);
		}
		b.end = scanner.end;
		return b;
	}

	// Parse a method.  Return the method object, or null on error.
	Method? parse_method(Method m) {
		m.start = scanner.start;
		if (!accept(Token.LEFT_PAREN)) {
			skip();
			return null;
		}
		while (true) {
			Parameter p = parse_parameter();
			if (p == null)
				break;
			m.parameters.add(p);
			if (!accept(Token.COMMA))
				break;
		}
		if (!accept(Token.RIGHT_PAREN)) {
			skip();
			return null;
		}
		if (!accept(Token.SEMICOLON)) {
			// Look for a left brace.  (There may be a throws clause in between.)
			Token t;
			do {
				t = next_token();
				if (t == Token.EOF)
					return null;
			} while (t != Token.LEFT_BRACE);
			m.body = parse_block();
		}
		m.end = scanner.end;
		return m;
	}
	
	Symbol? parse_method_or_field(string? enclosing_class) {
		CompoundName type = parse_type();
		if (type == null) {
			skip();
			return null;
		}
		if (peek_token() == Token.LEFT_PAREN && type.to_string() == enclosing_class)
			return parse_method(new Constructor());
		if (!accept(Token.ID)) {
			skip();
			return null;
		}
		switch (peek_token()) {
			case Token.SEMICOLON:
			case Token.EQUALS:
				Field f = new Field(type, scanner.val(), scanner.start, 0);
				skip();
				f.end = scanner.end;
				return f;
			case Token.LEFT_PAREN:
				Method m = new Method(scanner.val());
				return parse_method(m);
			default:
				skip();
				return null;
		}
	}

	bool is_modifier(Token t) {
		switch (t) {
			case Token.ABSTRACT:
			case Token.CONST:
			case Token.OVERRIDE:
			case Token.PRIVATE:
			case Token.PROTECTED:
			case Token.PUBLIC:
			case Token.STATIC:
			case Token.VIRTUAL:
			case Token.WEAK:
				return true;
			default:
				return false;
		}
	}

	void skip_attributes() {
		while (accept(Token.LEFT_BRACKET))
			while (next_token() != Token.RIGHT_BRACKET)
				;
	}

	void skip_modifiers() {
		while (is_modifier(peek_token()))
			next_token();
	}

	Construct? parse_construct() {
		if (!accept(Token.CONSTRUCT))
			return null;
		int start = scanner.start;
		if (!accept(Token.LEFT_BRACE))
			return null;
		Block b = parse_block();
		return b == null ? null : new Construct(b, start, scanner.end);
	}

	Node parse_member(string? enclosing_class) {
		skip_attributes();
		skip_modifiers();
		Token t = peek_token();
		switch (t) {
			case Token.CLASS:
			case Token.INTERFACE:
			case Token.STRUCT:
				return parse_class(false);
			case Token.ENUM:
				return parse_class(true);
			case Token.CONSTRUCT:
				return parse_construct();
			default:
				return parse_method_or_field(enclosing_class);
		}
	}

	Class? parse_class(bool is_enum) {
		next_token();	// move past 'class' or 'enum'
		if (!accept(Token.ID)) {
			skip();
			return null;
		}
		string name = scanner.val();
		Class cl = new Class(name);
		cl.start = scanner.start;
		if (!skip_to(Token.LEFT_BRACE))
			return null;
			
		if (is_enum) {
			while (!scanner.eof() && accept(Token.ID)) {
				Field f = new Field(new SimpleName(name), scanner.val(), scanner.start, 0);
				if (accept(Token.EQUALS))
					skip_expression();
				f.end = scanner.end;
				cl.members.add(f);
				if (!accept(Token.COMMA))
					break;
			}
			accept(Token.SEMICOLON);
		}
		
		while (!scanner.eof() && !accept(Token.RIGHT_BRACE)) {
			Node n = parse_member(name);
			if (n != null)
				cl.members.add(n);
		}
		
		cl.end = scanner.end;
		return cl;
	}

	string? parse_using() {
		if (!accept(Token.ID)) {
			skip();
			return null;
		}
		string s = scanner.val();
		skip();
		return s;
	}

	public SourceFile parse(string input) {
		scanner = new Scanner(input);
		SourceFile sf = new SourceFile();
		while (accept(Token.USING)) {
			string s = parse_using();
			if (s != null)
				sf.using_namespaces.add(s);
		}
		while (!scanner.eof()) {
			Symbol s = parse_member(null) as Symbol;
			if (s != null)
				sf.symbols.add(s);
		}
		return sf;
	}
	
	public CompoundName? name_at(string input, int pos) {
		scanner = new Scanner(input);
		while (scanner.end < pos) {
			Token t = scanner.next_token();
			if (t == Token.EOF)
				break;
			if (t == Token.ID) {
				CompoundName name = new SimpleName(scanner.val());
				while (true) {
					if (scanner.end >= pos)
						return name;
					if (!accept(Token.PERIOD) || !accept(Token.ID))
						break;
					name = new QualifiedName(name, scanner.val());
				}
			}
		}
		return null;
	}
}

void main(string[] args) {
    if (args.length < 2) {
        stderr.puts("usage: symbol <file>\n");
        return;
    }
    string source;
    if (!FileUtils.get_contents(args[1], out source)) {
    	stderr.puts("can't read file\n");
    	return;
    }
    SourceFile sf = new Parser().parse(source);
    sf.print(0);
}

