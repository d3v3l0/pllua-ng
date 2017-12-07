--

CREATE EXTENSION pllua_ng;

\set VERBOSITY terse


-- old-pllua compat shims
do language pllua_ng $$
  function fromstring(t,s) return pgtype(nil,t)(s) end
  function setshared(k,v) _ENV[k] = v end
  server.execute = spi.execute
  server.prepare = spi.prepare
  shared = _G
$$;
--

-- tests taken from old pllua
-- minimal function
CREATE FUNCTION hello(name text)
RETURNS text AS $$
  return string.format("Hello, %s!", name)
$$ LANGUAGE pllua_ng;
SELECT hello('PostgreSQL');

-- null handling
CREATE FUNCTION max(a integer, b integer) RETURNS integer AS $$
  if a == nil then return b end -- first arg is NULL?
  if b == nil then return a end -- second arg is NULL?
  return a > b and a or b -- return max(a, b)
$$ LANGUAGE pllua_ng;
SELECT max(1,2), max(2,1), max(2,null), max(null, 2), max(null, null);

-- plain recursive
CREATE FUNCTION fib(n int) RETURNS int AS $$
  if n < 3 then
    return n
  else
    return fib(n - 1) + fib(n - 2)
  end
$$ LANGUAGE pllua_ng;
SELECT fib(4);

-- memoized
CREATE FUNCTION fibm(n integer) RETURNS integer AS $$
  if n < 3 then return n
  else
    local v = _U[n]
    if not v then
      v = fibm(n - 1) + fibm(n - 2)
      _U[n] = v
    end
    return v
  end
end
do _U = {}
$$ LANGUAGE pllua_ng;
SELECT fibm(4);

-- tail recursive
CREATE FUNCTION fibt(n integer) RETURNS integer AS $$
  return _U(n, 0, 1)
end
_U = function(n, a, b)
  if n < 1 then return b
  else return _U(n - 1, b, a + b) end
$$ LANGUAGE pllua_ng;
SELECT fibt(4);

-- iterator
CREATE FUNCTION fibi() RETURNS integer AS $$
  while true do
    _U.curr, _U.next = _U.next, _U.curr + _U.next
    coroutine.yield(_U.curr)
  end
end
do
  _U = {curr = 0, next = 1}
  fibi = coroutine.wrap(fibi)
$$ LANGUAGE pllua_ng;
SELECT fibi(), fibi(), fibi(), fibi(), fibi();
SELECT fibi(), fibi(), fibi(), fibi(), fibi();

-- upvalue
CREATE FUNCTION counter() RETURNS int AS $$
  while true do
    _U = _U + 1
    coroutine.yield(_U)
  end
end
do
  _U = 0 -- counter
  counter = coroutine.wrap(counter)
$$ LANGUAGE pllua_ng;
SELECT counter();
SELECT counter();
SELECT counter();

-- record input
CREATE TYPE greeting AS (how text, who text);
CREATE FUNCTION makegreeting (g greeting, f text) RETURNS text AS $$
  return string.format(f, g.how, g.who)
$$ LANGUAGE pllua_ng;
SELECT makegreeting(('how', 'who'), '%s, %s!');

-- no worky yet
/*
-- array, record output
CREATE FUNCTION greetingset (how text, who text[])
RETURNS SETOF greeting AS $$
  for _, name in ipairs(who) do
    coroutine.yield{how=how, who=name}
  end
$$ LANGUAGE pllua_ng;
SELECT makegreeting(greetingset, '%s, %s!') FROM
  (SELECT greetingset('Hello', ARRAY['foo', 'bar', 'psql'])) AS q;

-- more array, upvalue
CREATE FUNCTION perm (a text[]) RETURNS SETOF text[] AS $$
  _U(a, #a)
end
do
  _U = function (a, n) -- permgen in PiL
    if n == 0 then
      coroutine.yield(a) -- return next SRF row
    else
      for i = 1, n do
        a[n], a[i] = a[i], a[n] -- i-th element as last one
        _U(a, n - 1) -- recurse on head
        a[n], a[i] = a[i], a[n] -- restore i-th element
      end
    end
  end
$$ LANGUAGE pllua_ng;
SELECT * FROM perm(array['1', '2', '3']);
*/
-- shared variables
CREATE FUNCTION getcounter() RETURNS integer AS $$
  if shared.counter == nil then -- not cached?
    setshared("counter", 0)
  end
  return counter -- _G.counter == shared.counter
$$ LANGUAGE pllua_ng;
CREATE FUNCTION setcounter(c integer) RETURNS void AS $$
  if shared.counter == nil then -- not cached?
    setshared("counter", c)
  else
    counter = c -- _G.counter == shared.counter
  end
$$ LANGUAGE pllua_ng;
SELECT getcounter();
SELECT setcounter(5);
SELECT getcounter();

-- SPI usage

CREATE TABLE sometable ( sid int4, sname text, sdata text);
INSERT INTO sometable VALUES (1, 'name', 'data');
/* no cursor yet
CREATE FUNCTION get_rows (i_name text) RETURNS SETOF sometable AS $$
  if _U == nil then -- plan not cached?
    local cmd = "SELECT sid, sname, sdata FROM sometable WHERE sname = $1"
    _U = server.prepare(cmd, {"text"}):save()
  end
  local c = _U:getcursor({i_name}, true) -- read-only
  while true do
    local r = c:fetch(1)
    if r == nil then break end
    r = r[1]
    coroutine.yield{sid=r.sid, sname=r.sname, sdata=r.sdata}
  end
  c:close()
$$ LANGUAGE pllua_ng;

SELECT * FROM get_rows('name');
*/

SET client_min_messages = warning;
CREATE TABLE tree (id INT PRIMARY KEY, lchild INT, rchild INT);
RESET client_min_messages;

CREATE FUNCTION filltree (t text, n int) RETURNS void AS $$
  local p = server.prepare("insert into " .. t .. " values($1, $2, $3)",
    {"int4", "int4", "int4"})
  for i = 1, n do
    local lchild, rchild = 2 * i, 2 * i + 1 -- siblings
    p:execute(i, lchild, rchild) -- insert values
  end
$$ LANGUAGE pllua_ng;
SELECT filltree('tree', 10);

CREATE FUNCTION preorder (t text, s int) RETURNS SETOF int AS $$
  coroutine.yield(s)
  local q = server.execute("select * from " .. t .. " where id=" .. s)
  if #q > 0 then
    local lchild, rchild = q[1].lchild, q[1].rchild -- store before next query
    if lchild ~= nil then preorder(t, lchild) end
    if rchild ~= nil then preorder(t, rchild) end
  end
$$ LANGUAGE pllua_ng;
SELECT * from preorder('tree', 1);
/* no cursor yet
CREATE FUNCTION postorder (t text, s int) RETURNS SETOF int AS $$
  local p = _U[t]
  if p == nil then -- plan not cached?
    p = server.prepare("select * from " .. t .. " where id=$1", {"int4"})
    _U[t] = p:save()
  end
  local c = p:getcursor({s}, true) -- read-only
  local q = c:fetch(1) -- one row
  if q ~= nil then
    local lchild, rchild = q[1].lchild, q[1].rchild -- store before next query
    c:close()
    if lchild ~= nil then postorder(t, lchild) end
    if rchild ~= nil then postorder(t, rchild) end
  end
  coroutine.yield(s)
end
do _U = {} -- plan cache
$$ LANGUAGE pllua_ng;
SELECT * FROM postorder('tree', 1);
*/

-- trigger
CREATE FUNCTION treetrigger() RETURNS trigger AS $$
  local row, operation = trigger.row, trigger.operation
  if operation == "update" then
    trigger.row = nil -- updates not allowed
  elseif operation == "insert" then
    local id, lchild, rchild = row.id, row.lchild, row.rchild
    if lchild == rchild or id == lchild or id == rchild -- avoid loops
        or (lchild ~= nil and _U.intree(lchild)) -- avoid cycles
        or (rchild ~= nil and _U.intree(rchild))
        or (_U.nonemptytree() and not _U.isleaf(id)) -- not leaf?
        then
      trigger.row = nil -- skip operation
    end
  else -- operation == "delete"
    if not _U.isleafparent(row.id) then -- not both leaf parent?
      trigger.row = nil
    end
  end
end
do
  local getter = function(cmd, ...)
    local plan = server.prepare(cmd, {...}):save()
    return function(...)
      return #(plan:execute(...)) > 0
    end
  end
  _U = { -- plan closures
    nonemptytree = getter("select * from tree"),
    intree = getter("select node from (select id as node from tree "
      .. "union select lchild from tree union select rchild from tree) as q "
      .. "where node=$1", "int4"),
    isleaf = getter("select leaf from (select lchild as leaf from tree "
      .. "union select rchild from tree except select id from tree) as q "
      .. "where leaf=$1", "int4"),
    isleafparent = getter("select lp from (select id as lp from tree "
      .. "except select ti.id from tree ti join tree tl on ti.lchild=tl.id "
      .. "join tree tr on ti.rchild=tr.id) as q where lp=$1", "int4")
  }
$$ LANGUAGE pllua_ng;

CREATE TRIGGER tree_trigger BEFORE INSERT OR UPDATE OR DELETE ON tree
  FOR EACH ROW EXECUTE PROCEDURE treetrigger();

SELECT * FROM tree WHERE id = 1;
UPDATE tree SET rchild = 1 WHERE id = 1;
SELECT * FROM tree WHERE id = 10;
DELETE FROM tree where id = 10;
DELETE FROM tree where id = 1;

-- passthru types
CREATE FUNCTION echo_int2(arg int2) RETURNS int2 AS $$ return arg $$ LANGUAGE pllua_ng;
SELECT echo_int2('12345');
CREATE FUNCTION echo_int4(arg int4) RETURNS int4 AS $$ return arg $$ LANGUAGE pllua_ng;
SELECT echo_int4('1234567890');
CREATE FUNCTION echo_int8(arg int8) RETURNS int8 AS $$ return arg $$ LANGUAGE pllua_ng;
SELECT echo_int8('1234567890');
SELECT echo_int8('12345678901236789');
SELECT echo_int8('1234567890123456789');
CREATE FUNCTION echo_text(arg text) RETURNS text AS $$ return arg $$ LANGUAGE pllua_ng;
SELECT echo_text('qwe''qwe');
CREATE FUNCTION echo_bytea(arg bytea) RETURNS bytea AS $$ return arg $$ LANGUAGE pllua_ng;
SELECT echo_bytea('qwe''qwe');
SELECT echo_bytea(E'q\\000w\\001e''q\\\\we');
CREATE FUNCTION echo_timestamptz(arg timestamptz) RETURNS timestamptz AS $$ return arg $$ LANGUAGE pllua_ng;
SELECT echo_timestamptz('2007-01-06 11:11 UTC') AT TIME ZONE 'UTC';
CREATE FUNCTION echo_timestamp(arg timestamp) RETURNS timestamp AS $$ return arg $$ LANGUAGE pllua_ng;
SELECT echo_timestamp('2007-01-06 11:11');
CREATE FUNCTION echo_date(arg date) RETURNS date AS $$ return arg $$ LANGUAGE pllua_ng;
SELECT echo_date('2007-01-06');
CREATE FUNCTION echo_time(arg time) RETURNS time AS $$ return arg $$ LANGUAGE pllua_ng;
SELECT echo_time('11:11');
CREATE FUNCTION echo_arr(arg text[]) RETURNS text[] AS $$ return arg $$ LANGUAGE pllua_ng;
SELECT echo_arr(array['a', 'b', 'c']);

CREATE DOMAIN mynum AS numeric(6,3);
CREATE FUNCTION echo_mynum(arg mynum) RETURNS mynum AS $$ return arg $$ LANGUAGE pllua_ng;
SELECT echo_mynum(666.777);

CREATE TYPE mytype AS (id int2, val mynum, val_list numeric[]);
CREATE FUNCTION echo_mytype(arg mytype) RETURNS mytype AS $$ return arg $$ LANGUAGE pllua_ng;
SELECT echo_mytype((1::int2, 666.777, array[1.0, 2.0]) );
/* no .rows yet
CREATE FUNCTION nested_server_rows () RETURNS SETOF text as
$$
for left in server.rows('select generate_series as left from generate_series(3,4) ') do
for right in server.rows('select generate_series as right from generate_series(5,6) ') do
	local s = left.left.." "..right.right
	coroutine.yield(s)
end
end
$$
language pllua_ng;
select nested_server_rows();
*/
CREATE OR REPLACE FUNCTION pg_temp.srf()
RETURNS SETOF integer AS $$
  coroutine.yield(1)
  coroutine.yield(nil)
  coroutine.yield(2)
$$ LANGUAGE pllua_ng;

select quote_nullable(pg_temp.srf());

CREATE OR REPLACE FUNCTION pg_temp.srf()
RETURNS SETOF integer AS $$
  coroutine.yield(1)
  coroutine.yield()
  coroutine.yield(2)
$$ LANGUAGE pllua_ng;

select quote_nullable(pg_temp.srf());

CREATE or replace FUNCTION pg_temp.inoutf(a integer, INOUT b text, INOUT c text)  AS
$$
begin
c = a||'c:'||c;
b = 'b:'||b;
end
$$
LANGUAGE plpgsql;

do $$
local a = server.execute("SELECT pg_temp.inoutf(5, 'ABC', 'd') as val ");
local r = a[1].val
print(r.b)
print(r.c)
$$ language pllua_ng;

-- body reload
SELECT hello('PostgreSQL');
CREATE OR REPLACE FUNCTION hello(name text)
RETURNS text AS $$
  return string.format("Bye, %s!", name)
$$ LANGUAGE pllua_ng;
SELECT hello('PostgreSQL');
--

--
-- new stuff
--

create type ctype3 as (fred integer, jim numeric);
create domain dtype as ctype3 check((VALUE).jim is not null);
create type ctype2 as (thingy text, wotsit integer);
create type ctype as (foo text, bar ctype2, baz dtype);
create table tdata (
    intcol integer,
    textcol text,
    charcol char(32),
    varcharcol varchar(32),
    compcol ctype,
    dcompcol dtype
);

insert into tdata
values (1, 'row 1', 'padded with blanks', 'not padded', ('x',('y',1111),(111,11.1)), (11,1.1)),
       (2, 'row 2', 'padded with blanks', 'not padded', ('x',('y',2222),(222,22.2)), (22,2.2)),
       (3, 'row 3', 'padded with blanks', 'not padded', ('x',('y',3333),(333,33.3)), (33,3.3));

create function tf1() returns setof tdata language pllua_ng as $f$
  for i = 1,4 do
    coroutine.yield({ intcol = i,
                      textcol = "row "..i,
		      charcol = "padded with blanks",
		      varcharcol = "not padded",
		      compcol = { foo = "x",
		      	      	  bar = { thingy = "y", wotsit = i*1111 },
				  baz = { fred = i*111, jim = i*11.1 }
				},
		      dcompcol = { fred = i*11, jim = i*1.1 }
		    });
  end
$f$;

select * from tf1();

--
-- various checks of type handling
--

do language pllua_ng $$ print(pgtype(nil,'ctype3')(1,2)) $$;
do language pllua_ng $$ print(pgtype(nil,'ctype3')({1,2})) $$;
do language pllua_ng $$ print(pgtype(nil,'ctype3')(true,true)) $$;
do language pllua_ng $$ print(pgtype(nil,'ctype3')("1","2")) $$;
do language pllua_ng $$ print(pgtype(nil,'ctype3')("fred","jim")) $$;
do language pllua_ng $$ print(pgtype(nil,'ctype3')({fred=1,jim=2})) $$;
do language pllua_ng $$ print(pgtype(nil,'ctype3')({fred=1,jim={}})) $$;
do language pllua_ng $$ print(pgtype(nil,'ctype3')({fred=1,jim=nil})) $$;
--do language pllua_ng $$ print(pgtype(nil,'dtype')({fred=1,jim=nil})) $$;

create function tf2() returns setof tdata language pllua_ng as $f$
  local t = spi.execute("select * from tdata")
  for i,v in ipairs(t) do coroutine.yield(v) end
$f$;

select * from tf2();


-- test numerics
create function lua_numexec(code text, n1 numeric, n2 numeric)
  returns text
  language pllua_ng
  as $$
    local f,e = load("return function(n1,n2) return "..code.." end")
    assert(f,e)
    f = f()
    assert(f)
    return tostring(f(n1,n2))
$$;
create function pg_numexec(code text, n1 numeric, n2 numeric)
  returns text
  language plpgsql
  as $$
    declare
      r text;
    begin
      execute format('select (%s)::text',
      	      	     regexp_replace(regexp_replace(code, '\mnum\.', '', 'g'),
		                    '\mn([0-9])', '$\1', 'g'))
	 into r using n1,n2;
      return r;
    end;
$$;


do language pllua_ng $$ num = require "pllua.numeric" $$;
with
  t as (select code,
               lua_numexec(code, 5439.123456, -1.9) as lua,
               pg_numexec(code, 5439.123456, -1.9) as pg
          from unnest(array[
		$$ n1 + n2 $$,		$$ n1 - n2 $$,
		$$ n1 * n2 $$,		$$ n1 / n2 $$,
		$$ n1 % n2 $$,		$$ n1 ^ n2 $$,
		$$ (-n1) + n2 $$,	$$ (-n1) - n2 $$,
		$$ (-n1) * n2 $$,	$$ (-n1) / n2 $$,
		$$ (-n1) % n2 $$,	$$ (-n1) ^ 3 $$,
		$$ (-n1) + (-n2) $$,	$$ (-n1) - (-n2) $$,
		$$ (-n1) * (-n2) $$,    $$ (-n1) / (-n2) $$,
		$$ (-n1) % (-n2) $$,	$$ (-n1) ^ (-3) $$,
		$$ (n1) > (n2) $$,	$$ (n1) < (n2) $$,
		$$ (n1) >= (n2) $$,	$$ (n1) <= (n2) $$,
		$$ (n1) > (n2*10000) $$,
		$$ (n1) < (n2*10000) $$,
		$$ (n1) >= (n2 * -10000) $$,
		$$ (n1) <= (n2 * -10000) $$,
		$$ num.round(n1) $$,    $$ num.round(n2) $$,
		$$ num.round(n1,4) $$,	$$ num.round(n1,-1) $$,
		$$ num.trunc(n1) $$,	$$ num.trunc(n2) $$,
		$$ num.trunc(n1,4) $$,	$$ num.trunc(n1,-1) $$,
		$$ num.floor(n1) $$,	$$ num.floor(n2) $$,
		$$ num.ceil(n1) $$,	$$ num.ceil(n2) $$,
		$$ num.abs(n1) $$,	$$ num.abs(n2) $$,
		$$ num.sign(n1) $$,	$$ num.sign(n2) $$,
		$$ num.sqrt(n1) $$,
		$$ num.exp(12.3) $$,
		$$ num.exp(n2) $$
  ]) as u(code))
select (lua = pg) as ok, * from t;
  
--end