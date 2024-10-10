module MySQLExt

using TidierDB
using DataFrames
using MySQL


__init__() = println("Extension was loaded!")

function TidierDB.connect(::mysql; kwargs...)
        set_sql_mode(mysql())
        # Required parameters by MySQL.jl: host and user
        host = get(kwargs, :host, "localhost")
        user = get(kwargs, :user, "")          
        password = get(kwargs, :password, "")  
        # Extract other optional parameters
        db = get(kwargs, :db, nothing)  
        port = get(kwargs, :port, nothing)     
        return DBInterface.connect(MySQL.Connection, host, user, password; db=db, port=port)
end


# MySQL
function TidierDB.get_table_metadata(conn::MySQL.Connection, table_name::String)
    # Query to get column names and types from INFORMATION_SCHEMA
    set_sql_mode(mysql());
    query = """
    SELECT column_name, data_type
    FROM information_schema.columns
    WHERE table_name = '$table_name'
    AND TABLE_SCHEMA = '$(conn.db)'
    ORDER BY ordinal_position;
    """

    result = DBInterface.execute(conn, query) |> DataFrame
    result[!, 2] = map(x -> String(x), result[!, 2])
    result[!, :current_selxn] .= 1
    result[!, :table_name] .= table_name
    # Adjust the select statement to include the new table_name column
    return DataFrames.select(result, :1 => :name, 2 => :type, :current_selxn, :table_name)
end


function TidierDB.final_collect(sqlquery::SQLQuery, ::Type{<:mysql})
    final_query = TidierDB.finalize_query(sqlquery)
    result = DBInterface.execute(sqlquery.db, final_query)
    return DataFrame(result)
end

function TidierDB.show_tables(conn::MySQL.Connection)
    return DataFrame(DBInterface.execute(conn, "SHOW TABLES"))
end

end


### save to database
import CSV
import DBInterface
using Chain


function collapse(x, sep = ",", left = "", right = "")
    left * reduce((a, b) -> a * sep * b, x) * right
end

collapse_sql(x) = collapse(string.(x), "`,`", "(`", "`)")

function write_special_csv(df; delim = "|!|", newline = "|#|", header = false, filename = "temp.csv")
    CSV.write(filename, df, delim = delim, newline = newline, header = header, missingstring="\\N")
end


"""
    copy_to2(df, table_name, con; replace = false)

Escreve no mariadb!!!

# Arguments
- df
- table_name
- con
- `replace`: should it replace on duplicate keys?
"""
function TidierDB.copy_to(df::DataFrames.AbstractDataFrame, table_name, con::MySQL.Connection; replace = false)
    db_names = names(con, table_name)
    df_names = names(df)
    common_names = intersect(db_names, df_names)

    if length(common_names) == 0 
        @warn "No columns in common! Returning nothing"
        return nothing
    end

    temp_file = tempname()

    df2 = DataFrames.select(df, common_names)

    write_special_csv(df2, filename = temp_file)

    comando = replace ? "REPLACE" : "IGNORE"


    query = """
LOAD DATA LOCAL INFILE '$(temp_file)' $comando INTO TABLE `$table_name`
CHARACTER SET 'utf8'
COLUMNS TERMINATED BY '|!|'
LINES TERMINATED BY '|#|'
$(collapse_sql(common_names));
"""

    output = DBInterface.execute(con, query)    

    Base.Filesystem.rm(temp_file)

    output
end

# get the columns of a table in a database
function Main.names(con::MySQL.Connection, table_name)
    query_columns = """SHOW COLUMNS FROM `$(table_name)`"""

    colunas_db =
        @chain begin
        DBInterface.execute(con, query_columns)
        DataFrame
        _.Field
        end

    colunas_db
end