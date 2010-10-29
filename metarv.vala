//using GLib;

/*
	TODO:
		1. log facility
		2. rrd integration
		3. formatted output
*/

class Config : Object {
	//private string config_path = Environment.get_home_dir() + "/.metarvrc";
	private string config_path = "./metarvrc";
	
	public static string last_file = "/tmp/metarv.last";

	public static string site_name 		= "rckh";
	public static string server_name 	= "weather.noaa.gov";
	
	public static string uri_path_metar = "/pub/data/observations/metar/stations/";
	public static string uri_path_filename;

	public static string format_output 	= "";
	public static string output_type		= "general";
	public static bool imperial_units	= false;

	class CmdOpt : Object {
		static const OptionEntry[] opts = {
			{ "site", 's', 0, OptionArg.STRING, ref site_name, "specify metar station.", "<name>" }, 
			{ "output", 't', 0, OptionArg.STRING, ref output_type, "output type: [general|raw|format] (default: general).", "<type>" }, 
			{ "format", 'f', 0, OptionArg.STRING, ref format_output, "customized formatted string. use '--format help' for more detail.", "<string>" }, 
			{ "imperial", 'i', 0, OptionArg.NONE, ref imperial_units, "use imperial units (feet, miles, fahrenheit), default is metric.", null },
			{ null }
		};
	
		public CmdOpt (string[] args) {
			try {
				var k = new OptionContext("- provides weather conditions decoded from METAR codes.");
				k.set_help_enabled(true);
				k.add_main_entries(opts, null);
				k.parse(ref args);
			} catch (OptionError e) {
				Metar.abnormal_exit(e, @"Run '$(args[0]) --help' to see a full list of available command line options.\n");
			}
		}
	}

	public Config (string[] args) {
		
		if (File.new_for_path(config_path).query_exists() == false) {
			stderr.printf("Creating configuration file: %s\n", config_path);
			this.write_config_file();
		} else {
			this.parse_config_file();
		}

		new CmdOpt(args);

		if (format_output == "help") {
			print_format_detail ();
		}
	}

	private void write_config_file () {
		var c = new KeyFile();
		c.set_string("service", "server_name", server_name);
		c.set_string("service", "uri_path_metar", uri_path_metar);
		c.set_string("service", "site_name", site_name);
		c.set_string("service", "output_type", output_type);
		c.set_string("service", "format_output", format_output);
		c.set_boolean("service", "imperial_units", imperial_units);

		try {
			FileUtils.set_contents(config_path, "# Automatically generated, only change if you know what you are doing.\n# If something goes wrong, let the program regenerate one for you.\n" + c.to_data());
		} catch (Error e) {
			Metar.abnormal_exit(e, "Failed to create a new configuration file.\n");
		}
	}

	private void parse_config_file () {
		var c = new KeyFile();
		try {
			c.load_from_file(config_path, KeyFileFlags.KEEP_COMMENTS);
			server_name			= c.get_string("service", "server_name");
			uri_path_metar 	= c.get_string("service", "uri_path_metar");
			site_name 			= c.get_string("service", "site_name").up();
			output_type			= c.get_string("service", "output_type");
			format_output		= c.get_string("service", "format_output");
			imperial_units		= c.get_boolean("service", "imperial_units");

		} catch (Error e) {
			Metar.abnormal_exit(e, "Configuration file parse error, try deleting it.\n");
		}
		uri_path_filename = uri_path_metar + site_name.up() + ".TXT";
	}

	private void print_format_detail () {
		stdout.printf("Available formatting options:\n\n");
		stdout.printf("  %%s = short station name\n");
		stdout.printf("  %%S = long station name \n");
		stdout.printf("  %%l = local time\n");
		stdout.printf("  %%t = temperature\n");
		stdout.printf("  %%d = dew point\n");
		stdout.printf("  %%w = wind speed\n");
		stdout.printf("  %%D = wind direction\n");
		stdout.printf("  %%g = wind gust speed\n");
		stdout.printf("\n");
		Posix.exit(0);
	}
}

class WeatherSite : Object {

	private InetAddress server_inet;
	private Config config;

	public string raw_text = "";

	public WeatherSite (Config config) {
		this.config = config;
		var resolver = Resolver.get_default();

		try {
			bool fetch_remote = false;
			if (File.new_for_path(config.last_file).query_exists() == true) {
				string temp;
				FileUtils.get_contents(config.last_file, out temp);
				if (temp.length != 0) {
					temp = temp.strip();

					var f = new DecodedData(temp);
					var d = new DateTime.now_local();
					var diff = d.difference(f.local);
					if (diff < 2400000000) {// wait 40 minutes (30 minutes per update + extra 10 minutes)
						raw_text = temp;
					} else {
						fetch_remote = true;
					}
				} else {
					fetch_remote = true;
				}
			} else {
				fetch_remote = true;
			}
			if (fetch_remote == true) {
				var addr_ls = resolver.lookup_by_name(config.server_name, null);
				server_inet = addr_ls.nth_data(0);
				this.get_raw();
				this.write_last();
			}
		} catch (Error e) {
			Metar.abnormal_exit(e, "Network failure.\n");
		}
	}

	private void get_raw () {
		try {
			var client = new SocketClient();
			var conn = client.connect (new InetSocketAddress (server_inet, 80), null);
			var mesg = "GET " + config.uri_path_filename + " HTTP/1.1\r\nHost: " + config.server_name + "\r\n\r\n";
			conn.output_stream.write (mesg, mesg.size(), null);

			// receive procedure

			var input = new DataInputStream (conn.input_stream);
			if (input.read_line(null, null).strip() == "HTTP/1.1 200 OK") {
				do {
					mesg = input.read_line(null, null).strip();
				} while (mesg != "");
				mesg = input.read_line(null, null);
				do {
					if (mesg[0:4] == config.site_name.up()) {
						raw_text = mesg.strip();
					}
					mesg = input.read_line(null, null);
				} while (mesg != null);
			}
		} catch (Error e) {
			Metar.abnormal_exit(e);
		}
	}

	private void write_last () {
		try {
			var f = File.new_for_path(config.last_file);
			var stream = f.replace(null, false, FileCreateFlags.NONE);
			var s = new DataOutputStream(stream);
			s.put_string(raw_text);
		} catch (Error e) {
			stderr.printf("(warning) %s\n(warning) There will be no cache until fixed.\n\n", e.message);
		}
	}
}



class DecodedData : Object {

	public class Wind : Object {
		
		public class Speed : Object {
			private double speed;
			private bool is_kt;

			public Speed (bool is_kt, double speed) {
				this.speed = speed;
				this.is_kt = is_kt;
			}

			public double get_mps () {
				if (is_kt)
					return speed*0.51444444;
				return speed;
			}

			public double get_kt () {
				if (is_kt)
					return speed;
				return speed*1.9438445;
			}

			public double get_mph () {
				if (is_kt)
					return speed*1.1507794;
				return speed*2.2369363;
			}

			public double get_kmph () {
				if (is_kt)
					return speed*1.852;
				return speed*3.6;
			}
		}

		public string direction;
		
		public Speed speed;
		public bool has_gust = false;
		public Speed gust;

		public bool has_vary = false;
		public string vary1;
		public string vary2;

		//public Wind () {}

		public void set_wind (bool is_kt, double number, string dir) {
			// type directly provided by METAR, either KT or MPS
			this.speed = new Speed (is_kt, number);
			this.direction = dir;
		}

		public void set_gust (bool is_kt, double number) {
			this.gust = new Speed (is_kt, number);
			this.has_gust = true;
		}

		public void set_vary (string dir1, string dir2) {
			if (vary1 != vary2 && has_vary == false) {
				vary1 = dir1;
				vary2 = dir2;
				has_vary = true;
			}
		}
	}

	public string raw_code;
	public string short_name;
	public double temperature;
	public double dew_point;
	public Wind wind;
	public double visibility;
	public double atmo_pressure;
	public DateTime local;
	public string[] extras = {};

	// Use of a enumeration to keep decoded fields

	private enum Flags {
		NAME = 1,
		TIME = 1 << 1,
		WIND = 1 << 2,
		WIND_VARY = 1 << 3,
		VISIBILITY = 1 << 4,
		ATMO_PRES = 1 << 5,
		TEMPERATURE = 1 << 6,
		NOSIG = 1 << 7
	}

	public DecodedData (string raw) {

		wind = new Wind ();

		raw_code = raw;
		var k = raw.split(" ");

		Flags flags = 0x0;

		foreach (var val in k) {
			// skip first if necessary
			if (val == "METAR")
				continue;

			if ((flags & Flags.NAME) == 0 && /^[A-Z]{4}$/.match(val)) {
				short_name = val;

				flags |= Flags.NAME;
			}

			// Time 
			if ((flags & Flags.TIME) == 0 && /^[0-9]+Z$/.match(val)) {
				DateTime utc;
				var now = new DateTime.now_utc ();
				utc = new DateTime.utc (now.get_year(), now.get_month(), val[0:2].to_int(), val[2:4].to_int(), val[4:6].to_int(), 0);
				local = utc.to_timezone(new TimeZone.local());

				flags |= Flags.TIME;
			}
			
			// Wind OOXX
			if ((flags & Flags.WIND) == 0 && /^(VRB)?[0-9G]+(MPS|KT)$/.match(val)) {
				string dirt = val[0:3];
				double speed = val[3:5].to_int();
				double gust = -1;

				int i = 5;
				if (val[5] == 'G') {
					gust = val[6:8].to_double();
					i = 8;
				}

				bool kt = true;
				if (val.substring(i) == "MPS")
					kt = false;
				
				if (gust != -1)
					wind.set_gust (kt, gust);
				wind.set_wind (kt, speed, dirt); 

				flags |= Flags.WIND;
			}

			// Temperature / dew point
			if ((flags & Flags.TEMPERATURE) == 0 && /^M?[0-9]+\/M?[0-9]+$/.match(val)) {
				string[] temp = val.split("/");
				temperature = temp[0].substring(-2).to_int();
				dew_point = temp[1].substring(-2).to_int();
				if (temp[0][0] == 'M')
					temperature *= -1;
				if (temp[1][0] == 'M')
					dew_point *= -1;

				flags |= Flags.TEMPERATURE;
			}
			
			// Wind Variation
			if ((flags & Flags.WIND_VARY) == 0 && /^[0-9]{3}V[0-9]{3}$/.match(val)) {
				string[] temp = val.split("V");
				wind.set_vary (temp[0], temp[1]);

				flags |= Flags.WIND_VARY;
			}

			// Visibility
			if ((flags & Flags.VISIBILITY) == 0 && /^[0-9]{4}$/.match(val)) {
				visibility = val.to_double();

				flags |= Flags.VISIBILITY;
			}

			if ((flags & Flags.VISIBILITY) == 0 && /^(M?[0-9]\/)?[0-9]+SM$/.match(val)) {
				if (val[0:4] == "M1/4") {
					// negative means lower than
					visibility = -400;
				} else {
					double f;
					if (val[1] == '/') {
						double a = val[0].to_string().to_int();
						double b = val[2].to_string().to_int();
						f = a/b;
					} else {
						f = val[0:-2].to_double();
					}
					visibility = f * 1609.344;
				}

				flags |= Flags.VISIBILITY;
				print (@"$visibility\n");
			}

			// Atmo Pressure
			if ((flags & Flags.ATMO_PRES) == 0 && /^Q[0-9]{4}$/.match(val)) {
				atmo_pressure = val.substring(1).to_double();

				flags |= Flags.ATMO_PRES;
			}

			if ((flags & Flags.ATMO_PRES) == 0 && /^A[0-9]{4}$/.match(val)) {
				atmo_pressure = val.substring(1).to_double() * 33.863886;
				flags |= Flags.ATMO_PRES;
			}

			// Weather cond OOXX !!

			// Extra informations
			if ((flags & Flags.NOSIG) == 0 && /^NOSIG$/.match(val)) {
				extras += "No significant weather change ahead.";

				flags |= Flags.NOSIG;
			}
		}
	}
}

class Formatter : Object {
	private DecodedData data;
	private Config config;

	public Formatter (Config conf, DecodedData data) {
		this.data = data;
		this.config = conf;
	}

	public void output () {
		switch (config.output_type) {
			case "general":
				print (@"Location    : %s, %s (%s)\n", GLOBAL[data.short_name].nth_data(3), GLOBAL[data.short_name].nth_data(5), data.short_name);
				print (@"Local time  : %s\n", data.local.format("%F %I:%M %p"));
				print (@"Temperature : $(data.temperature) C\n");
				print (@"Dew point   : $(data.dew_point) C\n");
				print (@"Wind        : $(data.wind.direction) ");
				if (data.wind.has_vary) {
					print (@"($(data.wind.vary1) - $(data.wind.vary2)");
				}
				print ("\nWind Speed  : %.2f kt (%.2f Km/hr)\n", data.wind.speed.get_kt(), data.wind.speed.get_kmph());
				print (@"Visibility  : ");
				if (data.visibility > 1000)
					print ("%.2f KM\n", data.visibility / 1000);
				else
					print (@"$(data.visibility) M");
				if (data.extras.length != 0) {
					print (@"Extra info  :");
					foreach (var val in data.extras) {
						print (@" $val");
					}
					print ("\n");
				}
				break;
			case "raw":
				print (@"$(data.raw_code)\n");
				break;
			case "format":
				break;
		}
	}

}

class SiteInfo : Object {
	private List<List<string>> list;

	public unowned List<string>? get (string s1) {
		var s = s1.up();
		if (/^[A-Z]{4}$/.match(s) == false)
			return null;
		unowned List<List<string>> iter = list.first();
		while (iter.data.nth_data(2) != s) {
			iter = iter.next;
		}
		return iter.data; 
	}

	public SiteInfo () {
		list = new List<List<string>> ();
		try {
			var f_input = File.new_for_path (DATA_DIR + "/stations.gz").read();
			var conv_input = new ConverterInputStream (f_input, new ZlibDecompressor(ZlibCompressorFormat.GZIP));
			var line_stream = new DataInputStream (conv_input);

			for (var line = line_stream.read_line(null); line != null; line = line_stream.read_line(null)) {
				var temp = new List<string> ();

				var array = line.split(";");
				for (int i=0; i<array.length; i++) {
					temp.prepend(array[i]);
				}
				temp.reverse();
				list.prepend((owned) temp);
			}
			list.reverse();
		} catch (Error e) {
			stderr.printf("(warning) Unable to read '%s', this file should have been shipped with metarv.\n", "stations.gz");
		}
	}
}

static SiteInfo GLOBAL;

// GLOBAL is a singleton-like class, which is initialized only once during main()
// query GLOBAL[<site name>] to get a List where its data structure looks like follows:
// .nth_data(0)  = block_number;
// .nth_data(1)  = station_number;
// .nth_data(2)  = icao_name;
// .nth_data(3)  = good_name;
// .nth_data(4)  = us_state;
// .nth_data(5)  = country;
// .nth_data(6)  = wmo_region;
// .nth_data(7)  = latitude;
// .nth_data(8)  = longtitude;
// .nth_data(9)  = upper_latitude;
// .nth_data(10) = upper_longtitude;
// .nth_data(11) = elevation;
// .nth_data(12) = upper_elevation;
// .nth_data(13) = rbsn;

class Metar : Object {

	public static void abnormal_exit(Error e, string str = "") {
		stderr.printf("Error: %s.\n", e.message);
		stderr.printf(str);
		Posix.exit(1);
	}

	public static int main (string[] args) {

		var config = new Config(args);
		var site = new WeatherSite(config);
		var weather = new DecodedData(site.raw_text);

		// initialize GLOBAL just before output, in case option parsing error.
		GLOBAL = new SiteInfo ();

		//var weather = new DecodedData("RCKH 220330Z 16013G23KT 290V310 3/8SM -SHRA FEW015 BKN035 OVC070 M28/M24 Q1000 TEMPO 1600 SHRA");
		var output = new Formatter(config, weather);
		output.output();

		return 0;
	}
}
