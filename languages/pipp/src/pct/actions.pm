# Copyright (C) 2008, The Perl Foundation.
# $Id$

=begin comments

Pipp::Grammar::Actions - AST transformations for Pipp

This file contains the methods that are used by the parse grammar
to build the PAST representation of a Pipp program.
Each method below corresponds to a rule in F<src/pct/grammar.pg>,
and is invoked at the point where C<{*}> appears in the rule,
with the current match object as the first argument.  If the
line containing C<{*}> also has a C<#= key> comment, then the
value of the comment is passed as the second argument to the method.

=end comments

=cut

class Pipp::Grammar::Actions;

method TOP($/, $key) {
    our @?BLOCK; # A stack of PAST::Block
   
    if $key eq 'open' {
        my $block := PAST::Block.new(
                         :node($/),
                         :hll('pipp')
                     );
        
        # set up scope 'package' for the superglobals
        # TODO: use a loop
        $block.symbol_defaults( :scope('lexical') );
        $block.symbol( :scope('package'), '$_GET' );
        $block.symbol( :scope('package'), '$_POST' );
        $block.symbol( :scope('package'), '$_SERVER' );
        $block.symbol( :scope('package'), '$_GLOBALS' );
        $block.symbol( :scope('package'), '$_FILES' );
        $block.symbol( :scope('package'), '$_COOKIE' );
        $block.symbol( :scope('package'), '$_SESSION' );
        $block.symbol( :scope('package'), '$_REQUEST' );
        $block.symbol( :scope('package'), '$_ENV' );
        @?BLOCK.unshift($block);
    }
    else {
        # retrieve the block created in the "if" section in this method.
        my $block := @?BLOCK.shift();

        # a PHP script consists of a list of statements
        for $<sea_or_code> {
            $block.push( $($_) );
        }

        make $block;
    }
}

method sea_or_code($/, $key) {
    make $( $/{$key} );
}

# The sea, text, surrounding the island, code, is printed out
method SEA($/) {
    make PAST::Op.new(
             :name('echo'),
             :node($/),
             PAST::Val.new(
                 :value(~$/),
                 :returns('PhpString')
             )
         );
}

method code_short_tag($/) {
    make $( $<statement_list> );
}

method code_echo_tag($/) {
    my $stmts := $( $<statement_list> );

    my $echo := $( $<argument_list> );
    $echo.name( 'echo' );

    $stmts.unshift( $echo );

    make $stmts;
}

method code_script_tag($/) {
    make $( $<statement_list> );
}

method statement($/, $key) {
    make $( $/{$key} );
}

method statement_list($/) {
    my $stmts := PAST::Stmts.new( :node($/) );
    for $<statement> {
        $stmts.push( $($_) );
    }

    make $stmts;
}

method inline_sea_short_tag($/) {
   make PAST::Op.new(
            PAST::Val.new(
                :value(~$<SEA_empty_allowed>),
                :returns('PhpString')
            ),
            :name('echo'),
            :node($/)
        );
}

method namespace_statement($/) {
    our $?NS := ~$<NAMESPACE_NAME>; 
    my $past := PAST::Op.new(
                    :pasttype('call'),
                    :name('echo'),
                    :node($/),
                    PAST::Val.new(
                        :value('Encountered namespace: ' ~ $?NS ~ "\n"),
                        :returns('PhpString'),
                    ),
                );
    make $past;
}

method return_statement($/) {
    my $past := PAST::Op.new(
                   :name('return'),
                   :pasttype('call'),
                   :node( $/ ),
                   $( $/<expression> )
               );

    make $past;
}

method require_once_statement($/) {
    my $past := PAST::Op.new(
                   :name('require'),
                   :pasttype('call'),
                   :node( $/ ),
                   $( $/<quote> )
               );

    make $past;
}

method echo_statement($/) {
    my $past := $( $<argument_list> );
    $past.name( 'echo' );

    make $past;
}

method expression_statement($/) {
    make $( $<expression> );
}

method closure_call($/) {
    my $past := $( $<argument_list> );
    $past.unshift( $( $<var> ) );

    make $past;
}

method function_call($/) {
    my $past := $( $<argument_list> );
    $past.name( ~$<FUNCTION_NAME> );

    make $past;
}

method instantiate_array($/) {
    my $past := PAST::Op.new(
                    :pasttype( 'call' ),
                    :name( 'array' ),
                    :node( $/ )
                );
  
    for $<array_argument> {
        $past.push( $($_) );
    }   

    make $past;
}

method array_argument($/, $key) {
    make $( $/{$key} );
}

method key_value_pair($/) { 
   make 
       PAST::Op.new(
           :node( $/ ),
           :pasttype( 'call' ),
           :name( 'infix:=>' ),
           :returns( 'Array' ),
           $( $<key> ),
           $( $<value> )
       );
}

method method_call($/) {
    my $past := $( $<argument_list> );
    $past.name( ~$<METHOD_NAME> );
    $past.pasttype( 'callmethod' );
    $past.unshift( $( $<var> ) );

    make $past;
}

method constructor_call($/) {
    make
        PAST::Op.new(
            :name( 'new' ),
            :pasttype( 'callmethod' ),
            PAST::Var.new(
                :name( ~$<CLASS_NAME> ),
                :scope( 'package' ),
            )
        );
}

method constant($/) {
    make PAST::Op.new(
             :name('constant'),
             PAST::Val.new(
                 :returns('PhpString'),
                 :value( ~$<CONSTANT_NAME> ),
             )
         );
}

# can be mergerd with constant
method class_constant($/) {
    make PAST::Op.new(
             :name('constant'),
             PAST::Val.new(
                 :returns('PhpString'),
                 :value( ~$/ ),
             )
         );
}

# class constants could probably also be set in a class init block
method class_constant_definition($/) {
    my $past := PAST::Block.new( :name('class_constant_definition') );
    my $loadinit := $past.loadinit();
    $loadinit.unshift(
       PAST::Op.new(
           :pasttype('call'),
           :name('define'),
           :node( $/ ),
           PAST::Val.new(
               :value( 'Foo::' ~ ~$<CONSTANT_NAME> ),
               :returns('PhpString'),
           ),
           $( $<literal> ),
       )
    );

    make $past;
}

method argument_list($/) {
    my $past := PAST::Op.new(
                    :pasttype('call'),
                    :node($/)
                );
    for $<expression> {
        $past.push( $($_) );
    }

    make $past;
}

method conditional_expression($/) {
    make
        PAST::Op.new(
            :node($/),
            $( $<expression> ),
            $( $<statement_list> )
        );
}

method do_while_statement($/) {
    make
        PAST::Op.new(
            :pasttype('repeat_while'),
            :node($/),
            $( $<expression> ),
            $( $<statement_list> )
        );
}

method if_statement($/) {
    my $past := $( $<conditional_expression> );
    $past.pasttype('if');
        
    my $else := undef;
    if +$<else_clause> {
        $else := $( $<else_clause>[0]<statement_list> );
    }
    my $first_eif := undef;
    if +$<elseif_clause> {
        my $count := +$<elseif_clause> - 1;
        $first_eif := $( $<elseif_clause>[$count] );
        while $count != 0 {
            my $eif := $( $<elseif_clause>[$count] );
            $count--;
            my $eifchild := $( $<elseif_clause>[$count] );
            if ($else) {
                $eif.push($else);
            }
            $eif.push($eifchild);
        }
        if $else && +$<elseif_clause> == 1 {
            $first_eif.push($else);
        }
     }

     if $first_eif {
         $past.push($first_eif);
     }
     elsif $else {
         $past.push($else);
     }

     make $past;
}

method elseif_clause($/) {
    my $past := $( $<conditional_expression> );
    $past.pasttype('if');

    make $past;
}

method var_assign($/) {
    make PAST::Op.new(
             $( $<var> ),
             $( $<expression> ),
             :pasttype('bind'),
         );
}

method array_elem($/) {
    our @?BLOCK;
    unless @?BLOCK[0].symbol( ~$<VAR_NAME> ) {
        @?BLOCK[0].symbol( ~$<VAR_NAME>, :scope('lexical') );
        @?BLOCK[0].push(
            PAST::Var.new(
                :name(~$<VAR_NAME>),
                :viviself('PhpArray'),
                :isdecl(1)
            )
        );
    }

    my $past_var_name := 
        PAST::Var.new(
            :name(~$<VAR_NAME>),
            :viviself('PhpArray'),
            :lvalue(1),
        );

    make PAST::Var.new(
             $past_var_name,
             $( $<expression> ),
             :scope('keyed'),
             :viviself('PhpNull'),
             :lvalue(1)
         );
}

method simple_var($/) {
    our @?BLOCK;
    unless @?BLOCK[0].symbol( ~$<VAR_NAME> ) {
        @?BLOCK[0].symbol( ~$<VAR_NAME>, :scope('lexical') );
        @?BLOCK[0].push(
            PAST::Var.new(
                :name(~$<VAR_NAME>),
                :viviself('PhpNull'),
                :isdecl(1)
            )
        );
    }

    make PAST::Var.new(
             :name(~$<VAR_NAME>),
             :viviself('PhpNull'),
             :lvalue(1),
         );
}

method var($/, $key) {
    make $( $/{$key} );
}

method this($/) {
    make PAST::Op.new(
             :inline( "%r = self" )
         );
}

method member($/) {
    make
        PAST::Op.new(
            :pasttype('callmethod'),
            :name('member'),
            PAST::Var.new(
                :name('$this'),
                :scope('lexical')
            )
        );
}

method while_statement($/) {
    my $past := $( $<conditional_expression> );
    $past.pasttype('while');
    make $past;
}

method for_statement($/) {
    my $init  := $( $<var_assign> );

    my $cond  := $( $<expression>[0] );
    my $work  := PAST::Stmts.new( $( $<statement_list> ), $( $<expression>[1] ) );
    my $while := PAST::Op.new(
                       $cond,
                       $work,
                       :pasttype('while'),
                 );

    make PAST::Stmts.new( $init, $while );
}


# Handle the operator precedence table.
method expression($/, $key) {
    if ($key eq 'end') {
        make $( $<expr> );
    }
    else {
        my $past := PAST::Op.new( :name($<type>),
                                  :pasttype($<top><pasttype>),
                                  :pirop($<top><pirop>),
                                  :lvalue($<top><lvalue>),
                                  :node($/)
                                );
        for @($/) {
            $past.push( $($_) );
        }
        make $past;
    }
}


method term($/, $key) {
    make $( $/{$key} );
}

method literal($/, $key) {
    make $( $/{$key} );
}

method TRUE($/) {
    make PAST::Val.new(
             :value( 1 ),
             :returns('PhpBoolean'),
             :node($/)
         );
}

method FALSE($/) {
    make PAST::Val.new(
             :value( 0 ),
             :returns('PhpBoolean'),
             :node($/)
         );
}

method NULL($/) {
    make PAST::Val.new(
             :value( 0 ),
             :returns('PhpNull'),
             :node($/)
         );
}

method INTEGER($/) {
    make PAST::Val.new(
             :value( ~$/ ),
             :returns('PhpInteger'),
             :node($/)
         );
}

method NUMBER($/) {
    make PAST::Val.new(
             :value( +$/ ),
             :returns('PhpFloat'),
             :node($/)
         );
}

method closure($/, $key) {
    our @?BLOCK; # A stack of PAST::Block

    if $key eq 'open' {
        # note that $<param_list> creates a new PAST::Block.
        my $block := $( $<param_list> );

        # declare the bound vars a lexical
        if +$<bind_list> == 1 {
            for $<bind_list>[0]<VAR_NAME> {
                $block.symbol( ~$_, :scope('lexical') ); 
            }
        }
        @?BLOCK.unshift( $block );
    }
    else {
        my $block := @?BLOCK.shift();

        $block.control('return_pir');
        $block.push( $( $<statement_list> ) );

        make $block;
    }
}

method function_definition($/, $key) {
    our @?BLOCK; # A stack of PAST::Block

    if $key eq 'open' {
        # note that $<param_list> creates a new PAST::Block.
        @?BLOCK.unshift( $( $<param_list> ) );
    }
    else {
        my $block := @?BLOCK.shift();

        $block.name( ~$<FUNCTION_NAME> );
        $block.control('return_pir');
        $block.push( $( $<statement_list> ) );

        make $block;
    }
}

method class_method_definition($/, $key) {
    our @?BLOCK; # A stack of PAST::Block

    if $key eq 'open' {
        # note that $<param_list> creates a new PAST::Block.
        my $block := $( $<param_list> );
        $block.unshift(
            PAST::Op.new(
                :pasttype('bind'),                                            
                PAST::Var.new(
                    :name('$this'),
                    :scope('lexical'),                                        
                    :isdecl(1)                                               
                ),                                                               
                PAST::Var.new(
                    :name('self'),                                            
                    :scope('register')                                       
                )                                                               
            )
        );                  

        @?BLOCK.unshift( $block );
    }
    else {
        my $block := @?BLOCK.shift();

        $block.name( ~$<METHOD_NAME> );
        $block.blocktype( 'method' );
        $block.control('return_pir');
        $block.push( $( $<statement_list> ) );

        make $block;
    }
}

method param_list($/) {

    my $block :=
        PAST::Block.new(
            :blocktype('declaration'),
            :node($/)
        );
    my $arity := 0;
    for $<VAR_NAME> {
        my $param :=
            PAST::Var.new(
                :name(~$_),
                :scope('parameter'),
                :viviself('PhpNull'),
                :lvalue(1),
            );
        $block.push($param);
        $arity++;
        $block.symbol( ~$_, :scope('lexical') ); 
    }
    $block.arity( $arity );

    make $block;
}

method class_definition($/, $key) {
    our @?BLOCK; # A stack of PAST::Block

    if $key eq 'open' {
        @?BLOCK.unshift(
            PAST::Block.new(
                :node($/),
                :blocktype('declaration'),
                :pirflags( ':init :load' )
            )
        );
    }
    else {
        my $block := @?BLOCK.shift();
        $block.namespace( $<CLASS_NAME><ident> );
        $block.push(
            PAST::Stmts.new(
                PAST::Op.new(
                    :inline(   "$P0 = get_root_global ['parrot'], 'P6metaclass'\n"
                             ~ "$P2 = $P0.'new_class'('" ~ $<CLASS_NAME> ~ "')\n" ),
                    :pasttype( 'inline' )
                )
            )
        );

        # nothing to do for $<const_definition,
        # setup of class constants is done in the 'loadinit' node
        for $<class_constant_definition> {
           $block.push( $($_) );
        }

        my $methods_block := PAST::Block.new( :blocktype('immediate') );

        # declare the attributes
        for $<class_member_definition> {
            $methods_block.symbol( ~$_<VAR_NAME><ident>, :scope('attribute') );
            $methods_block.push(
                PAST::Var.new(
                    :name(~$_<VAR_NAME><ident>),
                    :scope('attribute'),
                    :isdecl(1)
                )
            );
        }

        # add the methods
        for $<class_method_definition> {
            $methods_block.push( $($_) );
        }

        # add accessors for the attributes
        for $<class_member_definition> {
            $methods_block.push(
                PAST::Block.new(
                    :blocktype('declaration'),
                    :name(~$_<VAR_NAME><ident>),
                    :pirflags(':method'),
                    :node( $/ ),
                    PAST::Stmts.new(
                        PAST::Var.new(
                            :name(~$_<VAR_NAME><ident>),
                            :scope('attribute')
                        )
                    )
                )
            );
        }

        $block.push( $methods_block );

        make $block;
    }
}


method quote($/) {
    make $( $<quote_expression> );
}

method quote_expression($/, $key) {
    my $past;
    if $key eq 'quote_regex' {
        our $?NS;
        $past := PAST::Block.new(
            $<quote_regex>,
            :compiler('PGE::Perl6Regex'),
            :namespace($?NS),
            :blocktype('declaration'),
            :node( $/ )
        );
    }
    elsif $key eq 'quote_concat' {
        if +$<quote_concat> == 1 {
            $past := $( $<quote_concat>[0] );
        }
        else {
            $past := PAST::Op.new(
                :name('list'),
                :pasttype('call'),
                :node( $/ )
            );
            for $<quote_concat> {
                $past.push( $($_) );
            }
        }
    }
    make $past;
}

method quote_concat($/) {
    my $terms := +$<quote_term>;
    my $count := 1;
    my $past := $( $<quote_term>[0] );
    while ($count != $terms) {
        $past := PAST::Op.new(
            $past,
            $( $<quote_term>[$count] ),
            :pirop('concat'),
            :pasttype('pirop')
        );
        $count := $count + 1;
    }
    make $past;
}

method quote_term($/, $key) {
    my $past;
    if ($key eq 'literal') {
        $past := PAST::Val.new(
            :value( ~$<quote_literal> ),
            :returns('PhpString'),
            :node($/)
        );
    }
    else {
        $past := $( $/{ $key } );
    }

    make $past;
}

method curly_interpolation($/) {
    make $( $<var> );
}


# Local Variables:
#   mode: cperl
#   cperl-indent-level: 4
#   fill-column: 100
# End:
# vim: expandtab shiftwidth=4:
