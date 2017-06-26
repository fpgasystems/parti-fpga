library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity partitioner is
generic(ADDR_WIDTH : integer := 32;
		TUPLE_SIZE_BYTES : integer := 8; -- 8 16 32 64
		MAX_RADIX_BITS : integer := 13);
port(
	clk: in std_logic;
	resetn : in std_logic;

	read_request : out std_logic;
	read_request_address : out std_logic_vector(ADDR_WIDTH-1 downto 0);
	read_request_almostfull : in std_logic;

	read_response : in std_logic;
	read_response_data : in std_logic_vector(511 downto 0);
	read_response_address : in std_logic_vector(ADDR_WIDTH-1 downto 0);

	write_request : out std_logic;
	write_request_address : out std_logic_vector(ADDR_WIDTH-1 downto 0);
	write_request_data : out std_logic_vector(511 downto 0);
	write_request_almostfull : in std_logic;

	write_response : in std_logic;

	start : in std_logic;
	done : out std_logic;

	-- Parameters
	number_of_expected_CLs : in std_logic_vector(31 downto 0);
	number_of_CL_to_request : in std_logic_vector(31 downto 0);
	number_of_radix_bits : in std_logic_vector(31 downto 0);
	dummy_key : in std_logic_vector(31 downto 0);
	order_assignment_enable : in std_logic;
	generator_enable : in std_logic;
	write_back_disable : in std_logic;
	hash_select : in std_logic_vector(3 downto 0);
	padding_size_divider : in std_logic_vector(3 downto 0));
end partitioner;

architecture behavioral of partitioner is

constant pow13minus1 : unsigned(12 downto 0) := "1111111111111";
constant pow12minus1 : unsigned(12 downto 0) := "0111111111111";
constant pow11minus1 : unsigned(12 downto 0) := "0011111111111";
constant pow10minus1 : unsigned(12 downto 0) := "0001111111111";
constant pow9minus1 : unsigned(12 downto 0) := 	"0000111111111";
constant pow8minus1 : unsigned(12 downto 0) := 	"0000011111111";
constant pow7minus1 : unsigned(12 downto 0) := 	"0000001111111";
constant pow6minus1 : unsigned(12 downto 0) := 	"0000000111111";
constant pow5minus1 : unsigned(12 downto 0) := 	"0000000011111";
constant pow4minus1 : unsigned(12 downto 0) := 	"0000000001111";
constant pow3minus1 : unsigned(12 downto 0) := 	"0000000000111";
constant pow2minus1 : unsigned(12 downto 0) := 	"0000000000011";

constant ONE : unsigned(13 downto 0) := "00000000000001";
constant MAX_FANOUT : integer := 2**MAX_RADIX_BITS;
constant FIFO_DEPTH_BITS : integer := 8;
constant UNITS_NEEDED : integer := 64/TUPLE_SIZE_BYTES;
constant TUPLE_SIZE_BITS : integer := 8*TUPLE_SIZE_BYTES;

signal FANOUT : integer;
signal MASK : std_logic_vector(MAX_RADIX_BITS-1 downto 0);

signal PARTITION_SIZE : unsigned(31 downto 0) := (others => '0');
signal PARTITION_SIZE_WITH_PADDING : unsigned(31 downto 0) := (others => '0');
signal PADDING_SIZE_DIVIDER_INTERNAL : integer range 0 to 15 := 0;
signal IS_HIST_MODE : std_logic;

signal PARTITION_SIZE_WITH_PADDING_INTEGER : integer;

signal j : integer := 0;
signal i : integer := 0;
signal i_1d : integer := 0;
signal i_2d : integer := 0;
signal i_3d : integer := 0;
signal i_4d : integer := 0;

signal NumberOfExpectedCacheLines : unsigned(31 downto 0) := (others => '0');
signal NumberOfCacheLinesToRequest : unsigned(31 downto 0) := (others => '0');
signal NumberOfReceivedCacheLines : unsigned(31 downto 0) := (others => '0');
signal NumberOfRequestedReads : unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');
signal NumberOfCompletedReads : unsigned(31 downto 0) := (others => '0');
signal NumberOfRequestedWrites : unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');
signal NumberOfCompletedWrites : unsigned(31 downto 0) := (others => '0');

signal NumberOfDFIFOReads : unsigned(31 downto 0) := (others => '0');
signal NumberOfReadDifferential : unsigned(31 downto 0) := (others => '0');

signal read_response_internal : std_logic;
signal read_response_data_internal : std_logic_vector(511 downto 0);
signal write_response_internal : std_logic;

signal gen_en : std_logic;
signal gen_reset : std_logic;
signal gen_out_valid : std_logic;
signal gen_out_data : std_logic_vector(511 downto 0);
signal gen_send_disable : std_logic;

signal oa_en : std_logic;
signal oa_in_valid : std_logic;
signal oa_out_valid : std_logic;
signal oa_out_data : std_logic_vector(511 downto 0);
signal oa_out_almostfull : std_logic;
signal oa_fifos_free_count : std_logic_vector(31 downto 0);
signal oa_send_disable : std_logic;

type hash_data_type is array (UNITS_NEEDED-1 downto 0) of std_logic_vector(MAX_RADIX_BITS + TUPLE_SIZE_BITS - 1 downto 0);

signal hash_request : std_logic;
signal cl_of_keys : std_logic_vector(511 downto 0);
signal hash_out_valid : std_logic_vector(UNITS_NEEDED-1 downto 0);
signal hash_out_data : hash_data_type;

type fifo_data_type is array (UNITS_NEEDED-1 downto 0) of std_logic_vector(MAX_RADIX_BITS + TUPLE_SIZE_BITS - 1 downto 0);
type fifo_count_type is array (UNITS_NEEDED-1 downto 0) of std_logic_vector(FIFO_DEPTH_BITS-1 downto 0);

signal fifo_re : std_logic_vector(UNITS_NEEDED-1 downto 0);
signal fifo_valid : std_logic_vector(UNITS_NEEDED-1 downto 0);
signal fifo_din : fifo_data_type;
signal fifo_dout : fifo_data_type;
signal fifo_count :	fifo_count_type;
signal fifo_empty : std_logic_vector(UNITS_NEEDED-1 downto 0);
signal fifo_full : std_logic_vector(UNITS_NEEDED-1 downto 0);
signal fifo_almostfull: std_logic_vector(UNITS_NEEDED-1 downto 0);
signal fifos_almostfull : std_logic;
signal fifos_count : std_logic_vector(FIFO_DEPTH_BITS-1 downto 0) := (others => '0');
signal fifos_free_count : unsigned(FIFO_DEPTH_BITS-1 downto 0);

type dfifo_data_type is array (UNITS_NEEDED-1 downto 0) of std_logic_vector(4 + MAX_RADIX_BITS + 511 downto 0);

signal dfifo_re : std_logic_vector(UNITS_NEEDED-1 downto 0);
signal dfifo_valid : std_logic_vector(UNITS_NEEDED-1 downto 0);
signal dfifo_dout : dfifo_data_type;
signal dfifo_empty : std_logic_vector(UNITS_NEEDED-1 downto 0);
signal dfifo_almostfull : std_logic_vector(UNITS_NEEDED-1 downto 0);
signal dfifos_empty : std_logic;
signal dfifos_empty_d : std_logic_vector(63 downto 0);
signal dfifos_empty_end : std_logic;
signal dfifos_almostfull : std_logic;

signal aw_bram_we : std_logic;
signal aw_bram_re : std_logic;
signal aw_bram_raddr : std_logic_vector(MAX_RADIX_BITS-1 downto 0);
signal aw_bram_waddr : std_logic_vector(MAX_RADIX_BITS-1 downto 0);
signal aw_bram_din : std_logic_vector(31 downto 0);
signal aw_bram_dout : std_logic_vector(31 downto 0);

signal aw_bram_re_1d : std_logic;
signal aw_bram_raddr_1d : std_logic_vector(MAX_RADIX_BITS-1 downto 0);
signal aw_bram_waddr_1d : std_logic_vector(MAX_RADIX_BITS-1 downto 0);
signal aw_bram_din_1d : std_logic_vector(31 downto 0);

signal count_bram_we : std_logic;
signal count_bram_re : std_logic;
signal count_bram_raddr : std_logic_vector(MAX_RADIX_BITS-1 downto 0);
signal count_bram_waddr : std_logic_vector(MAX_RADIX_BITS-1 downto 0);
signal count_bram_din : std_logic_vector(31 downto 0);
signal count_bram_dout : std_logic_vector(31 downto 0);

signal count_bram_re_1d : std_logic;
signal count_bram_raddr_1d : std_logic_vector(MAX_RADIX_BITS-1 downto 0);
signal count_bram_waddr_1d : std_logic_vector(MAX_RADIX_BITS-1 downto 0);
signal count_bram_din_1d : std_logic_vector(31 downto 0);

signal counting : std_logic := '0';
signal finished : std_logic := '0';
signal finish_allowed : std_logic := '0';
signal resetted : std_logic := '0';
signal resetted_1d : std_logic := '0';
signal resetted_2d : std_logic := '0';
signal reserved_CL_for_counting : integer;

signal count_read_index : integer range 0 to MAX_FANOUT;
signal accumulation : integer;

signal fill_rate : std_logic_vector(3 downto 0);
signal fill_rate_1d : std_logic_vector(3 downto 0);
signal tuples : std_logic_vector(511 downto 0);
signal tuples_1d : std_logic_vector(511 downto 0);
signal bucket_address : std_logic_vector(ADDR_WIDTH-1 downto 0) := (others => '0');
signal cache_line_to_send : std_logic_vector(511 downto 0);
signal currently_reading_fill_rate : integer := 0;

signal ofifo_we :			std_logic;
signal ofifo_din :			std_logic_vector(511 + ADDR_WIDTH downto 0);	
signal ofifo_re :			std_logic;
signal ofifo_valid :		std_logic;
signal ofifo_dout :			std_logic_vector(511 + ADDR_WIDTH downto 0);
signal ofifo_count :		std_logic_vector(FIFO_DEPTH_BITS-1 downto 0);
signal ofifo_empty :		std_logic;
signal ofifo_full :			std_logic;
signal ofifo_almostfull: 	std_logic;

signal timers_written : std_logic;
signal timers_written_waiting : std_logic;
signal histogram_timer : unsigned(31 downto 0);
signal partitioning_timer : unsigned(31 downto 0);

component my_fifo
generic(
	FIFO_WIDTH : integer := 32;
	FIFO_DEPTH_BITS : integer := 8;
	FIFO_ALMOSTFULL_THRESHOLD : integer := 220);
port(
	clk :		in std_logic;
	reset_n :	in std_logic;

	we :		in std_logic;
	din :		in std_logic_vector(FIFO_WIDTH-1 downto 0);	
	re :		in std_logic;
	valid :		out std_logic;
	dout :		out std_logic_vector(FIFO_WIDTH-1 downto 0);
	count :		out std_logic_vector(FIFO_DEPTH_BITS-1 downto 0);
	empty :		out std_logic;
	full :		out std_logic;
	almostfull: out std_logic);
end component;

component simple_dual_port_ram_single_clock
generic(
	DATA_WIDTH : integer := 32;
	ADDR_WIDTH : integer := 8);
port(
	clk :	in std_logic;
	raddr : in std_logic_vector(ADDR_WIDTH-1 downto 0);
	waddr : in std_logic_vector(ADDR_WIDTH-1 downto 0);
	data : 	in std_logic_vector(DATA_WIDTH-1 downto 0);
	we :	in std_logic;
	q : 	out std_logic_vector(DATA_WIDTH-1 downto 0));
end component;

component generator
port (
	clk : in std_logic;
	resetn : in std_logic;

	in_enable : in std_logic;
	in_send_disable : in std_logic;
	in_reset_number_of_generated_lines : in std_logic;
	in_number_of_lines_to_generate : in std_logic_vector(31 downto 0);
	out_valid : out std_logic;
	out_data : out std_logic_vector(511 downto 0));
end component;

component order_assignment
port (
	clk : in std_logic;
	resetn : in std_logic;

	in_valid : in std_logic;
	in_data : in std_logic_vector(511 downto 0);
	in_send_disable : in std_logic;
	out_valid : out std_logic;
	out_data : out std_logic_vector(511 downto 0);
	out_almostfull : out std_logic;
	out_fifos_free_count : out std_logic_vector(31 downto 0));
end component;

component murmur
generic (
	KEY_BITS : integer := 32; -- 32 or 64
	PAYLOAD_BITS : integer := 32;
	HASH_BITS : integer := 20);
port (
	clk : in std_logic;
	resetn : in std_logic;
	hash_select : in std_logic_vector(3 downto 0);
	req_hash : in std_logic;
	in_data : in std_logic_vector(PAYLOAD_BITS + KEY_BITS - 1 downto 0);
	out_valid : out std_logic;
	out_data : out std_logic_vector(HASH_BITS + PAYLOAD_BITS + KEY_BITS - 1 downto 0));
end component;

component distributor
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
end component;

begin

read_response_internal <= read_response when gen_en = '0' else gen_out_valid;
read_response_data_internal <= read_response_data when gen_en = '0' else gen_out_data;
write_response_internal <= write_response when write_back_disable = '0' else ofifo_valid;

gen: generator
port map (
	clk => clk,
	resetn => resetn,

	in_enable => gen_en,
	in_send_disable => gen_send_disable,
	in_reset_number_of_generated_lines => gen_reset,
	in_number_of_lines_to_generate => number_of_expected_CLs,
	out_valid => gen_out_valid,
	out_data => gen_out_data);

oa_in_valid <= read_response_internal when oa_en = '1' else '0';
hash_request <= read_response_internal when oa_en = '0' else oa_out_valid;
cl_of_keys <= read_response_data_internal when oa_en = '0' else oa_out_data;

OA: order_assignment
port map (
	clk => clk,
	resetn => resetn,

	in_valid => oa_in_valid,
	in_data => read_response_data,
	in_send_disable => oa_send_disable,
	out_valid => oa_out_valid,
	out_data => oa_out_data,
	out_almostfull => oa_out_almostfull,
	out_fifos_free_count => oa_fifos_free_count);

Gen8B: if UNITS_NEEDED = 8 generate
	GenX: for k in 0 to 7 generate
		hashX : murmur
		generic map (
			KEY_BITS => 32,
			PAYLOAD_BITS => 32,
			HASH_BITS => MAX_RADIX_BITS)
		port map (
			clk => clk,
			resetn => resetn,
			hash_select => hash_select,
			req_hash => hash_request,
			in_data => cl_of_keys(63 + k*64 downto k*64),
			out_valid => hash_out_valid(k),
			out_data => hash_out_data(k));

		fifo_din(k) <= (hash_out_data(k)(64 + MAX_RADIX_BITS - 1 downto 64) and MASK) & hash_out_data(k)(63 downto 0);

		fifoX: my_fifo
		generic map (
			FIFO_WIDTH => MAX_RADIX_BITS + 64,
			FIFO_DEPTH_BITS => FIFO_DEPTH_BITS,
			FIFO_ALMOSTFULL_THRESHOLD => 240)
		port map (
			clk => clk,
			reset_n => resetn,

			we => hash_out_valid(k),
			din => fifo_din(k),
			re => fifo_re(k),
			valid => fifo_valid(k),
			dout => fifo_dout(k),
			count => fifo_count(k),
			empty => fifo_empty(k),
			full => fifo_full(k),
			almostfull => fifo_almostfull(k));

		distributorX: distributor
		generic map (
			TUPLE_SIZE_BITS => 64,
			MAX_RADIX_BITS => MAX_RADIX_BITS)
		port map (
			clk => clk,
			resetn => resetn,

			number_of_expected_tuples => number_of_expected_CLs,
			radix_bits => number_of_radix_bits,

			ififo_re => fifo_re(k),
			ififo_valid => fifo_valid(k),
			ififo_data => fifo_dout(k),
			ififo_empty => fifo_empty(k),

			ofifo_re => dfifo_re(k),
			ofifo_valid => dfifo_valid(k),
			ofifo_dout => dfifo_dout(k),
			ofifo_empty => dfifo_empty(k),
			ofifo_almostfull => dfifo_almostfull(k));
	end generate GenX;
	fifos_almostfull <= fifo_almostfull(7) or fifo_almostfull(6) or fifo_almostfull(5) or fifo_almostfull(4) or fifo_almostfull(3) or fifo_almostfull(2) or fifo_almostfull(1) or fifo_almostfull(0);
	fifos_count <= fifo_count(7) or fifo_count(6) or fifo_count(5) or fifo_count(4) or fifo_count(3) or fifo_count(2) or fifo_count(1) or fifo_count(0);
	dfifos_almostfull <= dfifo_almostfull(7) or dfifo_almostfull(6) or dfifo_almostfull(5) or dfifo_almostfull(4) or dfifo_almostfull(3) or dfifo_almostfull(2) or dfifo_almostfull(1) or dfifo_almostfull(0);
	dfifos_empty <= dfifo_empty(7) and dfifo_empty(6) and dfifo_empty(5) and dfifo_empty(4) and dfifo_empty(3) and dfifo_empty(2) and dfifo_empty(1) and dfifo_empty(0);
end generate Gen8B;
Gen16B: if UNITS_NEEDED = 4 generate
	GenX: for k in 0 to 3 generate
		hashX : murmur
		generic map (
			KEY_BITS => 64,
			PAYLOAD_BITS => 64,
			HASH_BITS => MAX_RADIX_BITS)
		port map (
			clk => clk,
			resetn => resetn,
			hash_select => hash_select,
			req_hash => hash_request,
			in_data => cl_of_keys(127 + k*128 downto k*128),
			out_valid => hash_out_valid(k),
			out_data => hash_out_data(k));

		fifo_din(k) <= (hash_out_data(k)(128 + MAX_RADIX_BITS - 1 downto 128) and MASK) & hash_out_data(k)(127 downto 0);

		fifoX: my_fifo
		generic map (
			FIFO_WIDTH => MAX_RADIX_BITS + 128,
			FIFO_DEPTH_BITS => FIFO_DEPTH_BITS,
			FIFO_ALMOSTFULL_THRESHOLD => 240)
		port map (
			clk => clk,
			reset_n => resetn,

			we => hash_out_valid(k),
			din => fifo_din(k),
			re => fifo_re(k),
			valid => fifo_valid(k),
			dout => fifo_dout(k),
			count => fifo_count(k),
			empty => fifo_empty(k),
			full => fifo_full(k),
			almostfull => fifo_almostfull(k));

		distributorX: distributor
		generic map (
			TUPLE_SIZE_BITS => 128,
			MAX_RADIX_BITS => MAX_RADIX_BITS)
		port map (
			clk => clk,
			resetn => resetn,

			number_of_expected_tuples => number_of_expected_CLs,
			radix_bits => number_of_radix_bits,

			ififo_re => fifo_re(k),
			ififo_valid => fifo_valid(k),
			ififo_data => fifo_dout(k),
			ififo_empty => fifo_empty(k),

			ofifo_re => dfifo_re(k),
			ofifo_valid => dfifo_valid(k),
			ofifo_dout => dfifo_dout(k),
			ofifo_empty => dfifo_empty(k),
			ofifo_almostfull => dfifo_almostfull(k));
	end generate GenX;
	fifos_almostfull <= fifo_almostfull(3) or fifo_almostfull(2) or fifo_almostfull(1) or fifo_almostfull(0);
	fifos_count <= fifo_count(3) or fifo_count(2) or fifo_count(1) or fifo_count(0);
	dfifos_almostfull <= dfifo_almostfull(3) or dfifo_almostfull(2) or dfifo_almostfull(1) or dfifo_almostfull(0);
	dfifos_empty <= dfifo_empty(3) and dfifo_empty(2) and dfifo_empty(1) and dfifo_empty(0);
end generate Gen16B;
Gen32B: if UNITS_NEEDED = 2 generate
	GenX: for k in 0 to 1 generate
		hashX : murmur
		generic map (
			KEY_BITS => 64,
			PAYLOAD_BITS => 192,
			HASH_BITS => MAX_RADIX_BITS)
		port map (
			clk => clk,
			resetn => resetn,
			hash_select => hash_select,
			req_hash => hash_request,
			in_data => cl_of_keys(255 + k*256 downto k*256),
			out_valid => hash_out_valid(k),
			out_data => hash_out_data(k));

		fifo_din(k) <= (hash_out_data(k)(256 + MAX_RADIX_BITS - 1 downto 256) and MASK) & hash_out_data(k)(255 downto 0);

		fifoX: my_fifo
		generic map (
			FIFO_WIDTH => MAX_RADIX_BITS + 256,
			FIFO_DEPTH_BITS => FIFO_DEPTH_BITS,
			FIFO_ALMOSTFULL_THRESHOLD => 240)
		port map (
			clk => clk,
			reset_n => resetn,

			we => hash_out_valid(k),
			din => fifo_din(k),
			re => fifo_re(k),
			valid => fifo_valid(k),
			dout => fifo_dout(k),
			count => fifo_count(k),
			empty => fifo_empty(k),
			full => fifo_full(k),
			almostfull => fifo_almostfull(k));

		distributorX: distributor
		generic map (
			TUPLE_SIZE_BITS => 256,
			MAX_RADIX_BITS => MAX_RADIX_BITS)
		port map (
			clk => clk,
			resetn => resetn,

			number_of_expected_tuples => number_of_expected_CLs,
			radix_bits => number_of_radix_bits,

			ififo_re => fifo_re(k),
			ififo_valid => fifo_valid(k),
			ififo_data => fifo_dout(k),
			ififo_empty => fifo_empty(k),

			ofifo_re => dfifo_re(k),
			ofifo_valid => dfifo_valid(k),
			ofifo_dout => dfifo_dout(k),
			ofifo_empty => dfifo_empty(k),
			ofifo_almostfull => dfifo_almostfull(k));
	end generate GenX;
	fifos_almostfull <= fifo_almostfull(1) or fifo_almostfull(0);
	fifos_count <= fifo_count(1) or fifo_count(0);
	dfifos_almostfull <= dfifo_almostfull(1) or dfifo_almostfull(0);
	dfifos_empty <= dfifo_empty(1) and dfifo_empty(0);
end generate Gen32B;
Gen64B: if UNITS_NEEDED = 1 generate
	GenX: for k in 0 to 0 generate
		hashX : murmur
		generic map (
			KEY_BITS => 64,
			PAYLOAD_BITS => 448,
			HASH_BITS => MAX_RADIX_BITS)
		port map (
			clk => clk,
			resetn => resetn,
			hash_select => hash_select,
			req_hash => hash_request,
			in_data => cl_of_keys,
			out_valid => hash_out_valid(k),
			out_data => hash_out_data(k));

		fifo_din(k) <= (hash_out_data(k)(512 + MAX_RADIX_BITS - 1 downto 512) and MASK) & hash_out_data(k)(511 downto 0);

		fifoX: my_fifo
		generic map (
			FIFO_WIDTH => MAX_RADIX_BITS + 512,
			FIFO_DEPTH_BITS => FIFO_DEPTH_BITS,
			FIFO_ALMOSTFULL_THRESHOLD => 240)
		port map (
			clk => clk,
			reset_n => resetn,

			we => hash_out_valid(k),
			din => fifo_din(k),
			re => fifo_re(k),
			valid => fifo_valid(k),
			dout => fifo_dout(k),
			count => fifo_count(k),
			empty => fifo_empty(k),
			full => fifo_full(k),
			almostfull => fifo_almostfull(k));

		distributorX: distributor
		generic map (
			TUPLE_SIZE_BITS => 512,
			MAX_RADIX_BITS => MAX_RADIX_BITS)
		port map (
			clk => clk,
			resetn => resetn,

			number_of_expected_tuples => number_of_expected_CLs,
			radix_bits => number_of_radix_bits,

			ififo_re => fifo_re(k),
			ififo_valid => fifo_valid(k),
			ififo_data => fifo_dout(k),
			ififo_empty => fifo_empty(k),

			ofifo_re => dfifo_re(k),
			ofifo_valid => dfifo_valid(k),
			ofifo_dout => dfifo_dout(k),
			ofifo_empty => dfifo_empty(k),
			ofifo_almostfull => dfifo_almostfull(k));
	end generate GenX;
	fifos_almostfull <= fifo_almostfull(0);
	fifos_count <= fifo_count(0);
	dfifos_almostfull <= dfifo_almostfull(0);
	dfifos_empty <= dfifo_empty(0);
end generate Gen64B;

already_written_bram: simple_dual_port_ram_single_clock
generic map (
	DATA_WIDTH => 32,
	ADDR_WIDTH => MAX_RADIX_BITS)
port map (
	clk => clk,
	raddr => aw_bram_raddr,
	waddr => aw_bram_waddr,
	data => aw_bram_din,
	we => aw_bram_we,
	q => aw_bram_dout);

count_bram: simple_dual_port_ram_single_clock
generic map (
	DATA_WIDTH => 32,
	ADDR_WIDTH => MAX_RADIX_BITS)
port map (
	clk => clk,
	raddr => count_bram_raddr,
	waddr => count_bram_waddr,
	data => count_bram_din,
	we => count_bram_we,
	q => count_bram_dout);

ofifo: my_fifo
generic map(
	FIFO_WIDTH => ADDR_WIDTH + 512,
	FIFO_DEPTH_BITS => FIFO_DEPTH_BITS,
	FIFO_ALMOSTFULL_THRESHOLD => 240)
port map(
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
	almostfull => ofifo_almostfull);

fifos_free_count <= to_unsigned(2**FIFO_DEPTH_BITS-1, FIFO_DEPTH_BITS) - unsigned(fifos_count);

IS_HIST_MODE <= '0' when PADDING_SIZE_DIVIDER_INTERNAL > 0 else '1';

process(clk)
variable current_count_bram_dout : unsigned(31 downto 0) := (others => '0');
variable current_aw_bram_dout : unsigned(31 downto 0) := (others => '0');
begin
if clk'event and clk = '1' then
----------------------------------------------------------------------------------------------------------------CONFIG BEGIN
	case to_integer(unsigned(number_of_radix_bits)) is
		when 13 =>
			MASK <= std_logic_vector(resize(pow13minus1, MAX_RADIX_BITS));
		when 12 =>
			MASK <= std_logic_vector(resize(pow12minus1, MAX_RADIX_BITS));
		when 11 =>
			MASK <= std_logic_vector(resize(pow11minus1, MAX_RADIX_BITS));
		when 10 =>
			MASK <= std_logic_vector(resize(pow10minus1, MAX_RADIX_BITS));
		when 9 =>
			MASK <= std_logic_vector(resize(pow9minus1, MAX_RADIX_BITS));
		when 8 =>
			MASK <= std_logic_vector(resize(pow8minus1, MAX_RADIX_BITS));
		when 7 =>
			MASK <= std_logic_vector(resize(pow7minus1, MAX_RADIX_BITS));
		when 6 =>
			MASK <= std_logic_vector(resize(pow6minus1, MAX_RADIX_BITS));
		when 5 =>
			MASK <= std_logic_vector(resize(pow5minus1, MAX_RADIX_BITS));
		when 4 =>
			MASK <= std_logic_vector(resize(pow4minus1, MAX_RADIX_BITS));
		when 3 =>
			MASK <= std_logic_vector(resize(pow3minus1, MAX_RADIX_BITS));
		when 2 =>
			MASK <= std_logic_vector(resize(pow2minus1, MAX_RADIX_BITS));
		when others =>
			MASK <= std_logic_vector(resize(pow13minus1, MAX_RADIX_BITS));
	end case;
	NumberOfCacheLinesToRequest <= unsigned(number_of_CL_to_request);
	NumberOfExpectedCacheLines <= unsigned(number_of_expected_CLs);
	FANOUT <= to_integer(shift_left(ONE, to_integer(unsigned(number_of_radix_bits))));

	PARTITION_SIZE <= shift_right(unsigned(number_of_expected_CLs), to_integer(unsigned(number_of_radix_bits)));
	PADDING_SIZE_DIVIDER_INTERNAL <= to_integer(unsigned(padding_size_divider));
	if PARTITION_SIZE > 64 then
		PARTITION_SIZE_WITH_PADDING <= PARTITION_SIZE + shift_right(PARTITION_SIZE, PADDING_SIZE_DIVIDER_INTERNAL);
	else
		PARTITION_SIZE_WITH_PADDING <= PARTITION_SIZE + X"00000040";
	end if;

	reserved_CL_for_counting <= to_integer(shift_right(to_unsigned(FANOUT, 32), 4));
----------------------------------------------------------------------------------------------------------------CONFIG END
	if dfifos_empty = '0' then
		dfifos_empty_d <= (others => '0');
	else
		dfifos_empty_d(0) <= dfifos_empty;
		for i in 1 to 63 loop
			dfifos_empty_d(i) <= dfifos_empty_d(i-1);
		end loop;
	end if;
	dfifos_empty_end <= dfifos_empty_d(63);

	tuples <= dfifo_dout(i_4d)(511 downto 0);
	tuples_1d <= tuples;

	if write_back_disable = '0' then
		write_request <= ofifo_valid;
		write_request_address <= ofifo_dout(511+ADDR_WIDTH downto 512);
		write_request_data <= ofifo_dout(511 downto 0);
	end if;

	NumberOfReadDifferential <= NumberOfRequestedReads(31 downto 0) - NumberOfCompletedReads;

	if resetn = '0' then
		i <= 0;
		i_1d <= 0;
		i_2d <= 0;
		i_3d <= 0;
		i_4d <= 0;

		if 0 <= j and j < MAX_FANOUT-1 then
			j <= j + 1;
		else
			j <= 0;
		end if;

		NumberOfExpectedCacheLines <= (others => '0');
		NumberOfCacheLinesToRequest <= (others => '0');
		NumberOfReceivedCacheLines <= (others => '0');
		NumberOfRequestedReads <= (others => '0');
		NumberOfCompletedReads <= (others => '0');
		NumberOfRequestedWrites <= (others => '0');
		NumberOfCompletedWrites <= (others => '0');

		NumberOfDFIFOReads <= (others => '0');

		gen_en <= '0';
		gen_reset <= '0';
		gen_send_disable <= '0';

		oa_en <= '0';
		oa_send_disable <= '0';

		dfifo_re <= (others => '0');

		aw_bram_we <= '1';
		aw_bram_re <= '0';
		aw_bram_raddr <= (others => '0');
		aw_bram_waddr <= std_logic_vector(to_unsigned(j, MAX_RADIX_BITS));
		aw_bram_din <= (others => '0');

		aw_bram_re_1d <= '0';
		aw_bram_raddr_1d <= (others => '0');
		aw_bram_waddr_1d <= (others => '0');
		aw_bram_din_1d <= (others => '0');

		count_bram_we <= '1';
		count_bram_re <= '0';
		count_bram_raddr <= (others => '0');
		count_bram_waddr <= std_logic_vector(to_unsigned(j, MAX_RADIX_BITS));
		count_bram_din <= (others => '0');

		count_bram_re_1d <= '0';
		count_bram_raddr_1d <= (others => '0');
		count_bram_waddr_1d <= (others => '0');
		count_bram_din_1d <= (others => '0');

		counting <= IS_HIST_MODE;
		finished <= '0';
		finish_allowed <= '0';
		resetted <= '0';
		resetted_1d <= '0';
		resetted_2d <= '0';
		
		count_read_index <= 0;
		accumulation <= 0;

		fill_rate <= (others => '0');
		fill_rate_1d <= (others => '0');
		bucket_address <= (others => '0');
		cache_line_to_send <= (others => '0');
		currently_reading_fill_rate <= 0;

		ofifo_we <= '0';
		ofifo_din <= (others => '0');
		ofifo_re <= '0';

		timers_written <= '0';
		timers_written_waiting <= '0';
		histogram_timer <= (others => '0');
		partitioning_timer <= (others => '0');

		read_request <= '0';
		read_request_address <= (others => '0');
	else
		if start = '1' then
			gen_en <= generator_enable;
		end if;
		if order_assignment_enable = '1' and generator_enable = '0' then
			oa_en <= '1';
		else
			oa_en <= '0';
		end if;

		gen_send_disable <= '0';
		oa_send_disable <= '0';
		if fifos_free_count < 10 or dfifos_almostfull = '1' then
			gen_send_disable <= '1';
			oa_send_disable <= '1';
		end if;

		-- Request Lines
		read_request <= '0';
		if start = '1' and NumberOfRequestedReads < NumberOfCacheLinesToRequest and read_request_almostfull = '0' and write_request_almostfull = '0' and oa_out_almostfull = '0' and NumberOfReadDifferential < fifos_free_count and NumberOfReadDifferential < unsigned(oa_fifos_free_count) then
			read_request <= '1';
			read_request_address <= std_logic_vector(NumberOfRequestedReads);
			NumberOfRequestedReads <= NumberOfRequestedReads + 1;
		end if;
		-- Receive Lines
		if read_response = '1' then
			NumberOfCompletedReads <= NumberOfCompletedReads + 1;
		end if;
		if hash_request = '1' then
			NumberOfReceivedCacheLines <= NumberOfReceivedCacheLines + 1;
		end if;

		-- Roundrobin read from the distributors
		if i = UNITS_NEEDED-1 then
			i <= 0;
		else
			i <= i + 1;
		end if;
		dfifo_re <= (others => '0');
		if dfifo_empty(i) = '0' and ofifo_almostfull = '0' then
			dfifo_re(i) <= '1';
		end if;

		aw_bram_re <= '0';
		count_bram_re <= '0';
		if dfifo_valid(i_4d) = '1' then
			NumberOfDFIFOReads <= NumberOfDFIFOReads + 1;
			aw_bram_re <= '1';
			aw_bram_raddr(MAX_RADIX_BITS-1 downto 0) <= dfifo_dout(i_4d)(MAX_RADIX_BITS + 511 downto 512);
			count_bram_re <= '1';
			count_bram_raddr(MAX_RADIX_BITS-1 downto 0) <= dfifo_dout(i_4d)(MAX_RADIX_BITS + 511 downto 512);
			fill_rate <= dfifo_dout(i_4d)(4 + MAX_RADIX_BITS + 511 downto MAX_RADIX_BITS + 512);
		elsif finished = '1' and counting = '1' and count_read_index < FANOUT then
			aw_bram_re <= '1';
			aw_bram_raddr <= std_logic_vector(to_unsigned(count_read_index, MAX_RADIX_BITS));
			count_bram_re <= '1';
			count_bram_raddr <= std_logic_vector(to_unsigned(count_read_index, MAX_RADIX_BITS));
			count_read_index <= count_read_index + 1;
		elsif finished = '1' and counting = '0' and count_read_index < FANOUT then
			aw_bram_re <= '1';
			aw_bram_raddr <= std_logic_vector(to_unsigned(count_read_index, MAX_RADIX_BITS));
			count_bram_re <= '1';
			count_bram_raddr <= std_logic_vector(to_unsigned(count_read_index, MAX_RADIX_BITS));
			count_read_index <= count_read_index + 1;
		end if;

		if (NumberOfCompletedWrites >= NumberOfExpectedCacheLines and NumberOfExpectedCacheLines > 0) or (counting = '1' and NumberOfDFIFOReads >= NumberOfExpectedCacheLines and NumberOfExpectedCacheLines > 0) then
			finish_allowed <= '1';
		end if;
		if NumberOfRequestedWrites = NumberOfCompletedWrites and dfifos_empty_end = '1' and finish_allowed = '1' then
			finished <= '1';
		end if;

		PARTITION_SIZE_WITH_PADDING_INTEGER <= to_integer(PARTITION_SIZE_WITH_PADDING)*to_integer(unsigned(aw_bram_raddr));

		aw_bram_we <= '0';
		count_bram_we <= '0';
		currently_reading_fill_rate <= 0;
		gen_reset <= '0';
		if count_bram_re_1d = '1' then
			if counting = '1' then
				if finished = '0' then
					if count_bram_raddr_1d = count_bram_waddr then
						current_count_bram_dout := unsigned(count_bram_din);
					elsif count_bram_raddr_1d = count_bram_waddr_1d then
						current_count_bram_dout := unsigned(count_bram_din_1d);
					else
						current_count_bram_dout := unsigned(count_bram_dout);
					end if;
					count_bram_we <= '1';
					count_bram_waddr <= count_bram_raddr_1d;
					count_bram_din <= std_logic_vector(current_count_bram_dout + 1);
				else
					aw_bram_we <= '1';
					aw_bram_waddr <= aw_bram_raddr_1d;
					aw_bram_din <= (others => '0');
					count_bram_we <= '1';
					count_bram_waddr <= count_bram_raddr_1d;
					count_bram_din <= std_logic_vector(to_unsigned(accumulation, 32));
					accumulation <= accumulation + to_integer(unsigned(count_bram_dout));
					case count_bram_raddr_1d(3 downto 0) is
						when B"0000" =>
							cache_line_to_send(31 downto 0) <= count_bram_dout;
						when B"0001" =>
							cache_line_to_send(63 downto 32) <= count_bram_dout;
						when B"0010" =>
							cache_line_to_send(95 downto 64) <= count_bram_dout;
						when B"0011" =>
							cache_line_to_send(127 downto 96) <= count_bram_dout;
						when B"0100" =>
							cache_line_to_send(159 downto 128) <= count_bram_dout;
						when B"0101" =>
							cache_line_to_send(191 downto 160) <= count_bram_dout;
						when B"0110" =>
							cache_line_to_send(223 downto 192) <= count_bram_dout;
						when B"0111" =>
							cache_line_to_send(255 downto 224) <= count_bram_dout;
						when B"1000" =>
							cache_line_to_send(287 downto 256) <= count_bram_dout;
						when B"1001" =>
							cache_line_to_send(319 downto 288) <= count_bram_dout;
						when B"1010" =>
							cache_line_to_send(351 downto 320) <= count_bram_dout;
						when B"1011" =>
							cache_line_to_send(383 downto 352) <= count_bram_dout;
						when B"1100" =>
							cache_line_to_send(415 downto 384) <= count_bram_dout;
						when B"1101" =>
							cache_line_to_send(447 downto 416) <= count_bram_dout;
						when B"1110" =>
							cache_line_to_send(479 downto 448) <= count_bram_dout;
						when B"1111" =>
							bucket_address(MAX_RADIX_BITS-5 downto 0) <= count_bram_raddr_1d(MAX_RADIX_BITS-1 downto 4);
							bucket_address(ADDR_WIDTH-1 downto MAX_RADIX_BITS-4) <= (others => '0');
							cache_line_to_send(511 downto 480) <= count_bram_dout;
							currently_reading_fill_rate <= 8; -- Mock fill rate, just to have it written to ofifo
							if count_read_index = FANOUT then
								NumberOfRequestedReads <= (others => '0');
								NumberOfCompletedReads <= (others => '0');
								NumberOfReceivedCacheLines <= (others => '0');
								gen_reset <= '1';
								counting <= '0';
								finished <= '0';
								finish_allowed <= '0';
								count_read_index <= 0;
							end if;
						when others =>
							--cache_line_to_send <= (others => '0');
					end case;
				end if;
			else
				if finished = '0' then
					if aw_bram_raddr_1d = aw_bram_waddr then
						current_aw_bram_dout := unsigned(aw_bram_din);
					elsif aw_bram_raddr_1d = aw_bram_waddr_1d then
						current_aw_bram_dout := unsigned(aw_bram_din_1d);
					else
						current_aw_bram_dout := unsigned(aw_bram_dout);
					end if;
					current_count_bram_dout := unsigned(count_bram_dout);
					if IS_HIST_MODE = '1' then
						bucket_address <= std_logic_vector(to_unsigned(to_integer(current_aw_bram_dout) + to_integer(current_count_bram_dout) + reserved_CL_for_counting, ADDR_WIDTH));
					else
						--bucket_address <= std_logic_vector(to_unsigned(to_integer(current_aw_bram_dout) + to_integer(PARTITION_SIZE_WITH_PADDING)*to_integer(unsigned(aw_bram_raddr_1d)) + reserved_CL_for_counting, ADDR_WIDTH));
						bucket_address <= std_logic_vector(to_unsigned(to_integer(current_aw_bram_dout) + PARTITION_SIZE_WITH_PADDING_INTEGER + reserved_CL_for_counting, ADDR_WIDTH));
					end if;
					cache_line_to_send <= tuples_1d;
					currently_reading_fill_rate <= to_integer(unsigned(fill_rate_1d));
					aw_bram_we <= '1';
					aw_bram_waddr <= aw_bram_raddr_1d;
					aw_bram_din <= std_logic_vector(current_aw_bram_dout + 1);
				else
					count_bram_we <= '1';
					count_bram_waddr <= count_bram_raddr_1d;
					count_bram_din <= (others => '0');
					aw_bram_we <= '1';
					aw_bram_waddr <= aw_bram_raddr_1d;
					aw_bram_din <= (others => '0');
					if IS_HIST_MODE = '1' then
						if count_read_index = FANOUT then
							resetted <= '1';
						end if;
					else
						case aw_bram_raddr_1d(3 downto 0) is
							when B"0000" =>
								cache_line_to_send(31 downto 0) <= aw_bram_dout;
							when B"0001" =>
								cache_line_to_send(63 downto 32) <= aw_bram_dout;
							when B"0010" =>
								cache_line_to_send(95 downto 64) <= aw_bram_dout;
							when B"0011" =>
								cache_line_to_send(127 downto 96) <= aw_bram_dout;
							when B"0100" =>
								cache_line_to_send(159 downto 128) <= aw_bram_dout;
							when B"0101" =>
								cache_line_to_send(191 downto 160) <= aw_bram_dout;
							when B"0110" =>
								cache_line_to_send(223 downto 192) <= aw_bram_dout;
							when B"0111" =>
								cache_line_to_send(255 downto 224) <= aw_bram_dout;
							when B"1000" =>
								cache_line_to_send(287 downto 256) <= aw_bram_dout;
							when B"1001" =>
								cache_line_to_send(319 downto 288) <= aw_bram_dout;
							when B"1010" =>
								cache_line_to_send(351 downto 320) <= aw_bram_dout;
							when B"1011" =>
								cache_line_to_send(383 downto 352) <= aw_bram_dout;
							when B"1100" =>
								cache_line_to_send(415 downto 384) <= aw_bram_dout;
							when B"1101" =>
								cache_line_to_send(447 downto 416) <= aw_bram_dout;
							when B"1110" =>
								cache_line_to_send(479 downto 448) <= aw_bram_dout;
							when B"1111" =>
								bucket_address(MAX_RADIX_BITS-5 downto 0) <= aw_bram_raddr_1d(MAX_RADIX_BITS-1 downto 4);
								bucket_address(ADDR_WIDTH-1 downto MAX_RADIX_BITS-4) <= (others => '0');
								cache_line_to_send(511 downto 480) <= aw_bram_dout;
								currently_reading_fill_rate <= 8; -- Mock fill rate, just to have it written to ofifo
								if count_read_index = FANOUT then
									resetted <= '1';
								end if;
							when others =>
								--cache_line_to_send <= (others => '0');
						end case;
					end if;
				end if;
			end if;
		end if;

		ofifo_we <= '0';
		if currently_reading_fill_rate > 0 then -- Write to Send FIFO
			ofifo_we <= '1';
			if currently_reading_fill_rate = 8 then
				ofifo_din <= bucket_address & cache_line_to_send(511 downto 0);
			elsif currently_reading_fill_rate = 7 then
				ofifo_din <= bucket_address & X"00000000"&dummy_key & cache_line_to_send(447 downto 0);
			elsif currently_reading_fill_rate = 6 then
				ofifo_din <= bucket_address & X"00000000"&dummy_key & X"00000000"&dummy_key & cache_line_to_send(383 downto 0);
			elsif currently_reading_fill_rate = 5 then
				ofifo_din <= bucket_address & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & cache_line_to_send(319 downto 0);
			elsif currently_reading_fill_rate = 4 then
				ofifo_din <= bucket_address & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & cache_line_to_send(255 downto 0);
			elsif currently_reading_fill_rate = 3 then
				ofifo_din <= bucket_address & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & cache_line_to_send(191 downto 0);
			elsif currently_reading_fill_rate = 2 then
				ofifo_din <= bucket_address & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & cache_line_to_send(127 downto 0);
			elsif currently_reading_fill_rate = 1 then
				ofifo_din <= bucket_address & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & cache_line_to_send(63 downto 0);
			end if;
		end if;
		if finished = '1' and counting = '0' and resetted_2d = '1' and timers_written = '0' then
			timers_written <= '1';
			ofifo_we <= '1';
			if IS_HIST_MODE = '1' then
				ofifo_din <= std_logic_vector(NumberOfRequestedWrites + 1) & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & std_logic_vector(histogram_timer) & std_logic_vector(partitioning_timer);
			else
				ofifo_din <= std_logic_vector(to_unsigned(to_integer(PARTITION_SIZE_WITH_PADDING)*FANOUT - 1 + reserved_CL_for_counting, ADDR_WIDTH)) & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & X"00000000"&dummy_key & std_logic_vector(histogram_timer) & std_logic_vector(partitioning_timer);
			end if;
		end if;

		ofifo_re <= '0';
		if ofifo_empty = '0' and write_request_almostfull = '0' then -- Send lines
			ofifo_re <= '1';	
		end if;

		if ofifo_valid = '1' then
			if timers_written = '1' then
				timers_written_waiting <= '1';
			end if;
			NumberOfRequestedWrites <= NumberOfRequestedWrites + 1;
		end if;

		if write_response_internal = '1' then
			NumberOfCompletedWrites <= NumberOfCompletedWrites + 1;
		end if;
		
		done <= '0';
		if timers_written_waiting = '1' and NumberOfRequestedWrites = NumberOfCompletedWrites and NumberOfCompletedWrites >= NumberOfExpectedCacheLines then
			done <= '1';
		end if;

		i_1d <= i;
		i_2d <= i_1d;
		i_3d <= i_2d;
		i_4d <= i_3d;
		aw_bram_re_1d <= aw_bram_re;
		aw_bram_raddr_1d <= aw_bram_raddr;
		aw_bram_waddr_1d <= aw_bram_waddr;
		aw_bram_din_1d <= aw_bram_din;
		count_bram_re_1d <= count_bram_re;
		count_bram_raddr_1d <= count_bram_raddr;
		count_bram_waddr_1d <= count_bram_waddr;
		count_bram_din_1d <= count_bram_din;
		fill_rate_1d <= fill_rate;

		resetted_1d <= resetted;
		resetted_2d <= resetted_1d;

		if start = '1' and counting = '1' then
			histogram_timer <= histogram_timer + 1;
		end if;
		if start = '1' then
			partitioning_timer <= partitioning_timer + 1;
		end if;

	end if;
end if;
end process;

end architecture;