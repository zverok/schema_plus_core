# frozen_string_literal: true

require 'ostruct'
require 'tsort'

module SchemaPlus
  module Core
    module ActiveRecord
      module SchemaDumper

        def self.prepended(base)
          base.class_eval do
            public :ignored?
          end
        end

        def dump(stream)
          @dump = SchemaDump.new(self)

          # If some other gem has a SchemaDumper, and it is higher than us in inheritance chain,
          # it still can write something into a "real" stream that would evade our redefined methods.
          # Tentatively consider that all it wrote can go to "header" (though it might be too naive).
          temp_stream = StringIO.new
          super temp_stream
          @dump.header += temp_stream.string

          @dump.assemble(stream)
        end

        def foreign_keys(table, _)
          stream = StringIO.new
          super table, stream
          @dump.final += stream.string.split("\n").map(&:strip)
        end

        def trailer(_)
          stream = StringIO.new
          super stream
          @dump.trailer = stream.string
        end

        def header(_)
          SchemaMonkey::Middleware::Dumper::Initial.start(dumper: self, connection: @connection, dump: @dump, initial: @dump.initial) do |env|
            stream = StringIO.new
            super stream
            env.dump.header = stream.string
          end
        end

        def extensions(_)
          stream = StringIO.new
          super stream
          @dump.extensions << stream.string unless stream.string.blank?
        end

        def types(_)
          stream = StringIO.new
          super stream
          @dump.types << stream.string unless stream.string.blank?
        end

        def tables(_)
          SchemaMonkey::Middleware::Dumper::Tables.start(dumper: self, connection: @connection, dump: @dump) do |env|
            # Other gems SchemaDumpers might redefine tables and, besides using methods like `table` inside
            # (which we override), they might also write directly to a stream.
            # For examples, https://github.com/bibendi/activerecord-postgres_enum/blob/v2.1.0/lib/active_record/postgres_enum/schema_dumper.rb
            # This gem overrides `tables` to drop `create_enum` statements into the stream before table definitions.
            #
            # Tentatively consider whatever is written this way as part of the header, though it might be too naive.
            stream = StringIO.new
            super stream
            @dump.header += stream.string
          end
        end

        TABLE_COLUMN_MATCHES = [
            [ # first match expression index case
                %r{
                  ^
                  t\.index \s*
                    "(?<index_cols>(?:[^"\\]|\\.)*?)" \s*
                    , \s*
                    name\: \s* [:'"](?<name>[^"\s]+)[,"]? \s*
                    ,? \s*
                    (?<options>.*)
                  $
                  }x,
                ->(m) {
                  index_cols = m[:index_cols].gsub('\\"', '"')
                  SchemaDump::Table::Index.new name: m[:name], columns: index_cols, options: eval("{" + m[:options] + "}")
                }
            ],
            [ # general matching of columns
                %r{
                  ^
                  t\.(?<type>\S+) \s*
                    [:'"](?<name>[^"\s]+)[,"]? \s*
                    ,? \s*
                    (?<options>.*)
                  $
                  }x,
                ->(m) {
                  SchemaDump::Table::Column.new name: m[:name], type: m[:type], options: eval("{" + m[:options] + "}"), comments: []
                }
            ],
            [ # index definitions with multiple columns
                %r{
                  ^
                  t\.index \s*
                    \[(?<index_cols>.*?)\] \s*
                    , \s*
                    name\: \s* [:'"](?<name>[^"\s]+)[,"]? \s*
                    ,? \s*
                    (?<options>.*)
                  $
                  }x,
                ->(m) {
                  index_cols = m[:index_cols].tr(%q{'":}, '').strip.split(/\s*,\s*/)
                  SchemaDump::Table::Index.new name: m[:name], columns: index_cols, options: eval("{#{m[:options]}}")
                }
            ]
        ].freeze

        def table(table, _)
          SchemaMonkey::Middleware::Dumper::Table.start(dumper: self, connection: @connection, dump: @dump, table: @dump.tables[table] = SchemaDump::Table.new(name: table)) do |env|
            stream = StringIO.new
            super env.table.name, stream
            m = stream.string.match %r{
            \A \s*
              create_table \s*
              [:'"](?<name>[^'"\s]+)['"]? \s*
              ,? \s*
              (?<options>.*) \s+
              do \s* \|t\| \s* $
            (?<columns>.*)
            ^\s*end\s*$
            (?<trailer>.*)
            \Z
            }xm
            if m.nil?
              env.table.alt = stream.string
            else
              env.table.pname = m[:name]
              env.table.options = m[:options].strip
              env.table.trailer = m[:trailer].split("\n").map(&:strip).reject{|s| s.blank?}
              table_objects = m[:columns].strip.split("\n").map { |col|
                cs = col.strip
                result = nil
                # find the first regex that matches and grab the column definition
                TABLE_COLUMN_MATCHES.find do |(r, l)|
                  m = cs.match r
                  result = m.nil? ? nil : l.call(m)
                end
                result
              }.reject { |o| o.nil? }
              env.table.columns = table_objects.select { |o| o.is_a? SchemaDump::Table::Column }
              env.table.indexes = table_objects.select { |o| o.is_a? SchemaDump::Table::Index }
            end
          end
        end
      end
    end
  end
end
