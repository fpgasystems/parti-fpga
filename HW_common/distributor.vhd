library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity distributor is
generic(
  TUPLE_SIZE_BITS : integer := 64; -- 64, 128, 256, 512
  MAX_RADIX_BITS : integer := 4);
port(
  clk : in std_logic;
  resetn : in std_logic;

  number_of_expected_tuples : in std_logic_vector(31 downto 0);
  radix_bits : in std_logic_vector(31 downto 0);

  ififo_re : out std_logic;
  ififo_valid : in std_logic;
  ififo_data : in std_logic_vector(MAX_RADIX_BITS + TUPLE_SIZE_BITS - 1 downto 0);
  ififo_empty : in std_logic;
  
  ofifo_re : in std_logic;
  ofifo_valid : out std_logic;
  ofifo_dout : out std_logic_vector(4 + MAX_RADIX_BITS + 511 downto 0);
  ofifo_empty : out std_logic;
  ofifo_almostfull : out std_logic);
end distributor;

architecture behavioral of distributor is

signal internal_resetn : std_logic;

constant ONE : unsigned(13 downto 0) := "00000000000001";
constant MAX_FANOUT : integer := 2**MAX_RADIX_BITS;
constant FIFO_DEPTH_BITS : integer := 10;
constant UNITS_NEEDED : integer := 512/TUPLE_SIZE_BITS;

signal INTERN_FANOUT : integer;

signal j : integer range 0 to MAX_FANOUT-1;

signal NumberOfExpectedTuples : integer;
signal NumberOfProcessedTuples : integer;

signal fr_bram_we : std_logic;
signal fr_bram_re : std_logic;
signal fr_bram_waddr : std_logic_vector(MAX_RADIX_BITS-1 downto 0);
signal fr_bram_raddr : std_logic_vector(MAX_RADIX_BITS-1 downto 0);
signal fr_bram_din : std_logic_vector(2 downto 0);
signal fr_bram_dout : std_logic_vector(2 downto 0);
signal flush_fr_bram_dout : std_logic_vector(2 downto 0);

signal fr_bram_re_1d : std_logic;
signal fr_bram_raddr_1d : std_logic_vector(MAX_RADIX_BITS-1 downto 0);
signal fr_bram_waddr_1d : std_logic_vector(MAX_RADIX_BITS-1 downto 0);
signal fr_bram_din_1d : std_logic_vector(2 downto 0);

type tuple_bram_addr_type is array (UNITS_NEEDED-1 downto 0) of std_logic_vector(MAX_RADIX_BITS-1 downto 0);
type tuple_bram_data_type is array (UNITS_NEEDED-1 downto 0) of std_logic_vector(TUPLE_SIZE_BITS-1 downto 0);

signal tuple_bram_we : std_logic_vector(UNITS_NEEDED-1 downto 0);
signal tuple_bram_re : std_logic_vector(UNITS_NEEDED-1 downto 0);
signal tuple_bram_waddr : tuple_bram_addr_type;
signal tuple_bram_raddr : tuple_bram_addr_type;
signal tuple_bram_din : tuple_bram_data_type;
signal tuple_bram_dout : tuple_bram_data_type;

signal ofifo_we : std_logic;
signal ofifo_din : std_logic_vector(4 + MAX_RADIX_BITS + 511 downto 0);  
signal ofifo_count : std_logic_vector(FIFO_DEPTH_BITS-1 downto 0);
signal ofifo_full :  std_logic;
signal intern_ofifo_almostfull : std_logic;

signal ofifo_din_signal : std_logic_vector(511 downto 0);

signal tuple : std_logic_vector(TUPLE_SIZE_BITS-1 downto 0);
signal tuple_1d : std_logic_vector(TUPLE_SIZE_BITS-1 downto 0);
signal tuple_2d : std_logic_vector(TUPLE_SIZE_BITS-1 downto 0);

signal tuple_bram_read : std_logic;
signal tuple_bram_read_1d : std_logic;
signal tuple_bram_read_2d : std_logic;
signal tuple_bram_read_address : std_logic_vector(MAX_RADIX_BITS-1 downto 0);
signal tuple_bram_read_address_1d : std_logic_vector(MAX_RADIX_BITS-1 downto 0);
signal tuple_bram_read_address_2d : std_logic_vector(MAX_RADIX_BITS-1 downto 0);

signal i : integer range 0 to MAX_FANOUT;
signal flush : std_logic;
signal flush_1d : std_logic;

component simple_dual_port_ram_single_clock
generic(
  DATA_WIDTH : integer := 32;
  ADDR_WIDTH : integer := 8);
port(
  clk :   in std_logic;
  raddr : in std_logic_vector(ADDR_WIDTH-1 downto 0);
  waddr : in std_logic_vector(ADDR_WIDTH-1 downto 0);
  data :  in std_logic_vector(DATA_WIDTH-1 downto 0);
  we :    in std_logic;
  q :     out std_logic_vector(DATA_WIDTH-1 downto 0));
end component;

component my_fifo
generic(
  FIFO_WIDTH : integer;
  FIFO_DEPTH_BITS : integer;
  FIFO_ALMOSTFULL_THRESHOLD: integer);
port(
  clk :    in std_logic;
  reset_n :  in std_logic;

  we :    in std_logic;
  din :    in std_logic_vector(FIFO_WIDTH-1 downto 0);  
  re :    in std_logic;
  valid :    out std_logic;
  dout :    out std_logic_vector(FIFO_WIDTH-1 downto 0);
  count :    out std_logic_vector(FIFO_DEPTH_BITS-1 downto 0);
  empty :    out std_logic;
  full :    out std_logic;
  almostfull: out std_logic);
end component;

begin

fr_bram: simple_dual_port_ram_single_clock
generic map (
  DATA_WIDTH => 3,
  ADDR_WIDTH => MAX_RADIX_BITS)
port map(
  clk => clk,
  raddr => fr_bram_raddr,
  waddr => fr_bram_waddr,
  data => fr_bram_din,
  we => fr_bram_we,
  q => fr_bram_dout);

GenX: for k in 0 to UNITS_NEEDED-1 generate
  tuple_bramX: simple_dual_port_ram_single_clock
  generic map (
    DATA_WIDTH => TUPLE_SIZE_BITS,
    ADDR_WIDTH => MAX_RADIX_BITS)
  port map(
    clk => clk,
    raddr => tuple_bram_raddr(k),
    waddr => tuple_bram_waddr(k),
    data => tuple_bram_din(k),
    we => tuple_bram_we(k),
    q => tuple_bram_dout(k));
  tuple_bram_din(k) <= tuple_2d;
end generate GenX;
GenOutput8: if UNITS_NEEDED = 8 generate
  ofifo_din_signal <= tuple_bram_dout(7) & tuple_bram_dout(6) & tuple_bram_dout(5) & tuple_bram_dout(4) & tuple_bram_dout(3) & tuple_bram_dout(2) & tuple_bram_dout(1) & tuple_bram_dout(0);
end generate GenOutput8;
GenOutput4: if UNITS_NEEDED = 4 generate
  ofifo_din_signal <= tuple_bram_dout(3) & tuple_bram_dout(2) & tuple_bram_dout(1) & tuple_bram_dout(0);
end generate GenOutput4;
GenOutput2: if UNITS_NEEDED = 2 generate
  ofifo_din_signal <= tuple_bram_dout(1) & tuple_bram_dout(0);
end generate GenOutput2;
GenOutput1: if UNITS_NEEDED = 1 generate
  ofifo_din_signal <= tuple_bram_dout(0);
end generate GenOutput1;

flush_fr_bram_dout <= fr_bram_dout when TUPLE_SIZE_BITS = 64 else
                      std_logic_vector(shift_left(unsigned(fr_bram_dout),1)) when TUPLE_SIZE_BITS = 128 else
                      std_logic_vector(shift_left(unsigned(fr_bram_dout),2)) when TUPLE_SIZE_BITS = 256 else
                      std_logic_vector(shift_left(unsigned(fr_bram_dout),3)) when TUPLE_SIZE_BITS = 512;

ofifo: my_fifo
generic map (
  FIFO_WIDTH => 4 + MAX_RADIX_BITS + 512,
  FIFO_DEPTH_BITS => FIFO_DEPTH_BITS,
  FIFO_ALMOSTFULL_THRESHOLD => 980)
port map (
  clk => clk,
  reset_n => resetn,

  we => ofifo_we,
  din => ofifo_din,
  re => ofifo_re,
  valid => ofifo_valid,
  dout => ofifo_dout,
  count => ofifo_count,
  empty => ofifo_empty,
  full => ofifo_full,
  almostfull => intern_ofifo_almostfull);

process(clk)
variable current_bram : integer range 0 to 8:= 0;
begin
if clk'event and clk = '1' then
  internal_resetn <= resetn;
  NumberOfExpectedTuples <= to_integer(unsigned(number_of_expected_tuples));

  ofifo_almostfull <= intern_ofifo_almostfull;
  INTERN_FANOUT <= to_integer(shift_left(ONE, to_integer(unsigned(radix_bits))));
  ofifo_din(511 downto 0) <= ofifo_din_signal;
  tuple <= ififo_data(TUPLE_SIZE_BITS-1 downto 0);
  tuple_1d <= tuple;
  tuple_2d <= tuple_1d;
  if internal_resetn = '0' then
    current_bram := 0;

    NumberOfProcessedTuples <= 0;

    ififo_re <= '0';

    if 0 <= j and j < MAX_FANOUT-1 then
      j <= j + 1;
    else
      j <= 0;
    end if;

    fr_bram_re <= '0';
    fr_bram_raddr <= (others => '0');
    fr_bram_we <= '1';
    fr_bram_waddr <= std_logic_vector(to_unsigned(j, MAX_RADIX_BITS));
    fr_bram_din <= (others => '0');

    fr_bram_re_1d <= '0';
    fr_bram_raddr_1d <= (others => '0');
    fr_bram_waddr_1d <= (others => '0');
    fr_bram_din_1d <= (others => '0');

    tuple_bram_re <= (others => '0');
    --tuple_bram_raddr <= (others => (others => '0'));
    tuple_bram_we <= (others => '1');
    tuple_bram_waddr <= (others => std_logic_vector(to_unsigned(j, MAX_RADIX_BITS)));
    --tuple_bram_din <= (others => (others => '0'));

    ofifo_we <= '0';
    ofifo_din(4 + MAX_RADIX_BITS + 511 downto 512) <= (others => '0');
    
    tuple_bram_read <= '0';
    tuple_bram_read_1d <= '0';
    tuple_bram_read_2d <= '0';
    tuple_bram_read_address <= (others => '0');
    tuple_bram_read_address_1d <= (others => '0');
    tuple_bram_read_address_2d <= (others => '0');

    i <= 0;
    flush <= '0';
    flush_1d <= '0';
  else
    ififo_re <= '0';
    if ififo_empty = '0' and intern_ofifo_almostfull = '0' then
      ififo_re <= '1';
    end if;

    fr_bram_re <= '0';
    tuple_bram_re <= (others => '0');
    if ififo_valid = '1' then
      fr_bram_re <= '1';
      fr_bram_raddr(MAX_RADIX_BITS-1 downto 0) <= ififo_data(MAX_RADIX_BITS + TUPLE_SIZE_BITS - 1 downto TUPLE_SIZE_BITS);
    elsif flush = '1' and i < INTERN_FANOUT and intern_ofifo_almostfull = '0' then
      fr_bram_re <= '1';
      fr_bram_raddr <= std_logic_vector(to_unsigned(i, MAX_RADIX_BITS));
      tuple_bram_re <= (others => '1');
      tuple_bram_raddr <= (others => std_logic_vector(to_unsigned(i, MAX_RADIX_BITS)));
      i <= i + 1;
    end if;

    fr_bram_re_1d <= fr_bram_re;
    fr_bram_raddr_1d <= fr_bram_raddr;

    fr_bram_we <= '0';
    tuple_bram_we <= (others => '0');
    tuple_bram_read <= '0';
    if fr_bram_re_1d = '1' and flush = '0' and flush_1d = '0' then
      if fr_bram_raddr_1d = fr_bram_waddr then
        current_bram := to_integer(unsigned(fr_bram_din));
      elsif fr_bram_raddr_1d = fr_bram_waddr_1d then
        current_bram := to_integer(unsigned(fr_bram_din_1d));
      else
        current_bram := to_integer(unsigned(fr_bram_dout));
      end if;
      fr_bram_we <= '1';
      fr_bram_waddr <= fr_bram_raddr_1d;
      if current_bram = UNITS_NEEDED-1 then
        fr_bram_din <= (others => '0');
        tuple_bram_read <= '1';
        tuple_bram_read_address <= fr_bram_raddr_1d;
      else
        fr_bram_din <= std_logic_vector(to_unsigned(current_bram + 1, 3));
      end if;
      tuple_bram_we(current_bram) <= '1';
      tuple_bram_waddr(current_bram) <= fr_bram_raddr_1d;
      --tuple_bram_din(current_bram) <= tuple_1d;
      NumberOfProcessedTuples <= NumberOfProcessedTuples + 1;
    end if;
    
    fr_bram_waddr_1d <= fr_bram_waddr;
    fr_bram_din_1d <= fr_bram_din;

    if tuple_bram_read = '1' then
      tuple_bram_re <= (others => '1');
      tuple_bram_raddr <= (others => tuple_bram_read_address);
    end if;

    if NumberOfProcessedTuples >= NumberOfExpectedTuples and ififo_empty = '1' and tuple_bram_read = '0' and tuple_bram_read_1d = '0' and tuple_bram_read_2d = '0' and ofifo_we = '0' then
      flush <= '1';
    end if;

    ofifo_we <= '0';
    if tuple_bram_read_2d = '1' then
      ofifo_we <= '1';
      ofifo_din(4 + MAX_RADIX_BITS + 511 downto 512) <= B"1000" & tuple_bram_read_address_2d;
    elsif fr_bram_re_1d = '1' and flush_1d = '1' and fr_bram_dout /= B"000" then
      fr_bram_we <= '1';
      fr_bram_waddr <= fr_bram_raddr_1d;
      fr_bram_din <= B"000";
      ofifo_we <= '1';
      ofifo_din(4 + MAX_RADIX_BITS + 511 downto 512) <= '0' & flush_fr_bram_dout & fr_bram_raddr_1d;
    end if;
    if i = INTERN_FANOUT then
      NumberOfProcessedTuples <= 0;
      i <= 0;
      flush <= '0';
    end if;

    flush_1d <= flush;
    
    tuple_bram_read_1d <= tuple_bram_read;
    tuple_bram_read_address_1d <= tuple_bram_read_address;
    tuple_bram_read_2d <= tuple_bram_read_1d;
    tuple_bram_read_address_2d <= tuple_bram_read_address_1d;

  end if;
end if;
end process;

end behavioral;