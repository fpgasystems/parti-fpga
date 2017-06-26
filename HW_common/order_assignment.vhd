----------------------------------------------------------------------------
--  Copyright (C) 2017 Kaan Kara - Systems Group, ETH Zurich

--  This program is free software: you can redistribute it and/or modify
--  it under the terms of the GNU Affero General Public License as published
--  by the Free Software Foundation, either version 3 of the License, or
--  (at your option) any later version.

--  This program is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU Affero General Public License for more details.

--  You should have received a copy of the GNU Affero General Public License
--  along with this program. If not, see <http://www.gnu.org/licenses/>.
----------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity order_assignment is
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
end order_assignment;

architecture behavioral of order_assignment is

constant FIFO_DEPTH_BITS : integer := 8;

signal order : unsigned(31 downto 0) := (others => '0');

type fifo_data_type is array (1 downto 0) of std_logic_vector(511 downto 0);
type fifo_count_type is array (1 downto 0) of std_logic_vector(FIFO_DEPTH_BITS-1 downto 0);

signal fifo_we : std_logic_vector(1 downto 0);
signal fifo_re : std_logic_vector(1 downto 0);
signal fifo_valid : std_logic_vector(1 downto 0);
signal fifo_din : fifo_data_type;
signal fifo_dout : fifo_data_type;
signal fifo_count :	fifo_count_type;
signal fifo_empty : std_logic_vector(1 downto 0);
signal fifo_full : std_logic_vector(1 downto 0);
signal fifo_almostfull: std_logic_vector(1 downto 0);
signal fifos_count : std_logic_vector(FIFO_DEPTH_BITS-1 downto 0) := (others => '0');
signal fifos_free_count : integer range 0 to 2**FIFO_DEPTH_BITS-1;

signal i : integer range 0 to 1;

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

begin

GenX: for k in 0 to 1 generate
	fifoX: my_fifo
	generic map (
		FIFO_WIDTH => 512,
		FIFO_DEPTH_BITS => FIFO_DEPTH_BITS,
		FIFO_ALMOSTFULL_THRESHOLD => 240)
	port map (
		clk => clk,
		reset_n => resetn,

		we => fifo_we(k),
		din => fifo_din(k),
		re => fifo_re(k),
		valid => fifo_valid(k),
		dout => fifo_dout(k),
		count => fifo_count(k),
		empty => fifo_empty(k),
		full => fifo_full(k),
		almostfull => fifo_almostfull(k));
end generate GenX;

out_fifos_free_count <= std_logic_vector(to_unsigned(fifos_free_count, 32)) when fifos_free_count > 80 else
						(others => '0');

fifos_count <= fifo_count(1) or fifo_count(0);
fifos_free_count <= (2**FIFO_DEPTH_BITS-1) - to_integer(unsigned(fifos_count));

out_almostfull <= fifo_almostfull(1) or fifo_almostfull(0);
out_valid <= fifo_valid(1) or fifo_valid(0);
out_data <= fifo_dout(1) when fifo_valid(1) = '1' else
			fifo_dout(0) when fifo_valid(0) = '1' else
			fifo_dout(0);

process(clk)
begin
if clk'event and clk = '1' then
	if resetn = '0' then
		order <= (others => '0');
		i <= 0;
	else
		fifo_we(0) <= '0';
		fifo_we(1) <= '0';
		if in_valid = '1' then
			fifo_we(0) <= '1';
			fifo_din(0) <=	std_logic_vector(order + 7) & in_data(255 downto 224) & std_logic_vector(order + 6) & in_data(223 downto 192) &
							std_logic_vector(order + 5) & in_data(191 downto 160) & std_logic_vector(order + 4) & in_data(159 downto 128) &
							std_logic_vector(order + 3) & in_data(127 downto 96) & std_logic_vector(order + 2) & in_data(95 downto 64) &
							std_logic_vector(order + 1) & in_data(63 downto 32) & std_logic_vector(order) & in_data(31 downto 0);

			fifo_we(1) <= '1';
			fifo_din(1) <=	std_logic_vector(order + 15) & in_data(511 downto 480) & std_logic_vector(order + 14) & in_data(479 downto 448) &
							std_logic_vector(order + 13) & in_data(447 downto 416) & std_logic_vector(order + 12) & in_data(415 downto 384) &
							std_logic_vector(order + 11) & in_data(383 downto 352) & std_logic_vector(order + 10) & in_data(351 downto 320) &
							std_logic_vector(order + 9) & in_data(319 downto 288) & std_logic_vector(order + 8) & in_data(287 downto 256);

			order <= order + 16;
		end if;

		fifo_re <= (others => '0');
		if fifo_empty(i) = '0' and in_send_disable = '0' then
			fifo_re(i) <= '1';
			if i = 0 then
				i <= 1;
			else
				i <= 0;
			end if;
		end if;
	end if;
end if;
end process;

end architecture;