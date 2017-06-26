library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity generator is
port (
	clk : in std_logic;
	resetn : in std_logic;

	in_enable : in std_logic;
	in_send_disable : in std_logic;
	in_reset_number_of_generated_lines : in std_logic;
	in_number_of_lines_to_generate : in std_logic_vector(31 downto 0);
	out_valid : out std_logic;
	out_data : out std_logic_vector(511 downto 0));
end generator;

architecture behavioral of generator is

signal NumberOfLinesToGenerate : integer := 0;

signal GeneratedNumberOfLines : integer := 0;
signal order : unsigned(31 downto 0) := (others => '0');

begin

NumberOfLinesToGenerate <= to_integer(unsigned(in_number_of_lines_to_generate));

process(clk)
begin
if clk'event and clk = '1' then
	if resetn = '0' OR in_reset_number_of_generated_lines = '1' then
		GeneratedNumberOfLines <= 0;
		order <= (others => '0');

		out_valid <= '0';
		out_data <= (others => '0');
	else
		out_valid <= '0';
		if in_enable = '1' and GeneratedNumberOfLines < NumberOfLinesToGenerate and in_send_disable = '0' then
			out_valid <= '1';
			out_data <=	X"00000000" & std_logic_vector(order + 7) & X"00000000" & std_logic_vector(order + 6) &
						X"00000000" & std_logic_vector(order + 5) & X"00000000" & std_logic_vector(order + 4) &
						X"00000000" & std_logic_vector(order + 3) & X"00000000" & std_logic_vector(order + 2) &
						X"00000000" & std_logic_vector(order + 1) & X"00000000" & std_logic_vector(order);

			order <= order + 8;
			GeneratedNumberOfLines <= GeneratedNumberOfLines + 1;
		end if;
	end if;
end if;
end process;

end architecture;