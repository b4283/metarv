//using GLib;

/*
	TODO:
		1. log facility
		2. rrd integration
		3. formatted output
*/

void println (string f) {
	print ("%s\n", f);
}

class Config : Object {
	//private string config_path = Environment.get_home_dir() + "/.metarvrc";
	private string config_path = "./metarvrc";
	
	public static string cache_file = "/tmp/metarv.cache";

	public static string site_name 		= "rckh";
	public static string server_name 	= "weather.noaa.gov";
	
	public static string uri_path_metar = "/pub/data/observations/metar/stations/";

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
		sanity_check();

		if (format_output == "help") {
			print_format_detail ();
		}
	}

	private void sanity_check () {
		if (/^[a-zA-Z]{4}$/.match(site_name) == false)
			error("Invalid station name");
		site_name = site_name.up();
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

	public string raw_text = "";

	public WeatherSite () {
		var resolver = Resolver.get_default();

		bool fetch_remote = false;

		try {
			if (File.new_for_path(config.cache_file).query_exists() == true) {
				var keyfile = new KeyFile ();
				keyfile.load_from_file(config.cache_file, KeyFileFlags.NONE);
				if (keyfile.has_key("cache", config.site_name)) {
					string temp = keyfile.get_string("cache", config.site_name);
					if (temp.length != 0) {
						temp = temp.strip();

						var f = new DecodedData(temp);
						var d = new DateTime.now_local();
						var diff = d.difference(f.local);
						if (diff < 2400000000) {
							// wait 40 minutes (30 minutes per update + extra 10 minutes)
							raw_text = temp;
						} else {
							fetch_remote = true;
						}
					} else
						fetch_remote = true;
				} else
					fetch_remote = true;
			} else
				fetch_remote = true;
		} catch (Error e) {
			stderr.printf ("Error parsing cache file: %s\n\n", e.message);
		}

		try {
			if (fetch_remote == true) {
				var addr_ls = resolver.lookup_by_name(config.server_name, null);
				server_inet = addr_ls.nth_data(0);
				this.get_remote_raw();
				this.write_cache();
			}
		} catch (Error e) {
			Metar.abnormal_exit(e, "Network failure.\n");
		}
	}

	private void get_remote_raw () throws IOError {
		try {
			var client = new SocketClient();
			var conn = client.connect (new InetSocketAddress (server_inet, 80), null);
			var mesg = @"GET $(config.uri_path_metar)$(config.site_name).TXT HTTP/1.1\r\nHost: $(config.server_name)\r\n\r\n";
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
			} else {
				throw new IOError.NOT_FOUND(@"Unable to find data for station $(config.site_name)");
			}
		} catch (Error e) {
			Metar.abnormal_exit(e);
		}
	}

	private void write_cache () {
		try {
			var f = new KeyFile();
			if (File.new_for_path(config.cache_file).query_exists() == true)
				f.load_from_file(config.cache_file, KeyFileFlags.NONE);
			f.set_string("cache", config.site_name, raw_text);
			FileUtils.set_contents (config.cache_file, f.to_data());
		} catch (Error e) {
			stderr.printf("%s\nUnable to write a cache file, there will be no cache until fixed.\n\n", e.message);
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
			
			public double smart (bool imp) {
				return imp?(this.get_mph()):(this.get_kmph());
			}

			public string smart_unit (bool imp) {
				return imp?"mph":"km/h";
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

	public class Distance : Object {
		public static enum Unit {
			FEET,
			METER,
			MILE,
		}

		private double dist;

		// always store as meter
		public Distance (double in, Unit type) {
			switch (type) {
				case Unit.FEET:
					dist = in*0.3048;
					break;
				case Unit.MILE:
					dist = in*1609.344;
					break;
				case Unit.METER:
					dist = in;
					break;
			}
		}

		public double get_meter () {
			return dist;
		}

		public double get_feet () {
			return dist*3.2808399;
		}

		public double get_mile () {
			return dist*0.00062137119;
		}

		public double human (bool imp) {
			if (imp == false) {
				if (dist > 1000)
					return dist/1000;
				else if (dist < 1)
					return dist*100;
				else
					return dist;
			} else {
				if (dist > 1609)
					return dist/1609.344;
				else
					return dist*3.2808399;
			}
		}

		public string human_unit (bool imp) {
			if (imp == false) {
				if (dist > 1000)
					return "km";
				else if (dist < 1)
					return "cm";
				else
					return "m";
			} else {
				if (dist > 1609)
					return "miles";
				else
					return "feet";
			}
		}
	}

	public class Temperature : Object {
		public enum Unit {
			CELSIUS,
			FAHRENHEIT
		}
		private double num;

		public Temperature (double num, Unit type) {
			if (type == Unit.CELSIUS)
				this.num = num;
			else
				this.num = (num - 32) / 1.8;
		}

		public double celsius () {
			return num;
		}

		public double fahrenheit () {
			return num*1.8+32;
		}

		public double smart (bool imp) {
			return imp?this.fahrenheit():num;
		}

		public string smart_unit (bool imp) {
			return imp?"F":"C";
		}
	}

	public class Pressure : Object {
		public enum Unit {
			HPA, // (Qxxxx)
			INHG // (Axxxx)
		}
		private double num;

		public Pressure (double num, Unit type) {
			if (type == Unit.INHG)
				num *= 33.863886;
			this.num = num;
		}

		public double get_hpa () {
			return num;
		}

		public double get_inhg () {
			return num/33.863886;
		}

		public double smart (bool imp) {
			return imp?(this.get_inhg()):(this.get_hpa());
		}

		public string smart_unit (bool imp) {
			return imp?"inHg":"hPa";
		}
	}

	public string raw_code;
	public string short_name;
	public Temperature temperature;
	public Temperature dew_point;
	public Wind wind;
	public Distance visibility;
	public Pressure atmo_pressure;
	public DateTime local;
	public string[] extras = {};
	public string[] phenomena = {};
	public string[] sky = {};

	// Use of a enumeration to keep decoded fields
	private enum Flags {
		NAME = 1,
		TIME = 1 << 1,
		WIND = 1 << 2,
		WIND_VARY = 1 << 3,
		VISIBILITY = 1 << 4,
		ATMO_PRES = 1 << 5,
		TEMPERATURE = 1 << 6
	}

	public DecodedData (string raw) {

		wind = new Wind ();

		raw_code = raw;
		var k = raw.split(" ");

		Flags flags = 0x0;

		foreach (var val in k) {
			bool parsed = false;

			// skip first if necessary
			if (val == "METAR") {
				parsed = true;
				continue;
			}

			if ((flags & Flags.NAME) == 0 && /^[A-Z]{4}$/.match(val)) {
				short_name = val;

				flags |= Flags.NAME;
				parsed = true;
			}
			
			// Time 
			if ((flags & Flags.TIME) == 0 && /^[0-9]+Z$/.match(val)) {
				DateTime utc;
				var now = new DateTime.now_utc ();
				utc = new DateTime.utc (now.get_year(), now.get_month(), val[0:2].to_int(), val[2:4].to_int(), val[4:6].to_int(), 0);
				local = utc.to_timezone(new TimeZone.local());

				flags |= Flags.TIME;
				parsed = true;
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
				parsed = true;
			}

			// Temperature / dew point
			if ((flags & Flags.TEMPERATURE) == 0 && /^M?[0-9]+\/M?[0-9]+$/.match(val)) {
				string[] temp = val.split("/");
				double a, b;
				a = temp[0].substring(-2).to_double();
				b = temp[1].substring(-2).to_double();
				if (temp[0][0] == 'M')
					a *= -1;
				if (temp[1][0] == 'M')
					b *= -1;

				temperature = new Temperature (a, Temperature.Unit.CELSIUS);
				dew_point = new Temperature (b, Temperature.Unit.CELSIUS);

				flags |= Flags.TEMPERATURE;
				parsed = true;
			}
			
			// Wind Variation
			if ((flags & Flags.WIND_VARY) == 0 && /^[0-9]{3}V[0-9]{3}$/.match(val)) {
				string[] temp = val.split("V");
				wind.set_vary (temp[0], temp[1]);

				flags |= Flags.WIND_VARY;
				parsed = true;
			}

			// Visibility
			if ((flags & Flags.VISIBILITY) == 0 && /^[0-9]{4}$/.match(val)) {
				visibility = new Distance (val.to_double(), Distance.Unit.METER);

				flags |= Flags.VISIBILITY;
				parsed = true;
			}

			if ((flags & Flags.VISIBILITY) == 0 && /^(M?[0-9]\/)?[0-9]+SM$/.match(val)) {
				double f;

				if (val[0:4] == "M1/4") {
					// negative means lower than
					f = 0.25;
				} else {
					if (val[1] == '/') {
						double a = val[0].to_string().to_int();
						double b = val[2].to_string().to_int();
						f = a/b;
					} else {
						f = val[0:-2].to_double();
					}
				}
				visibility = new Distance (f, Distance.Unit.MILE);

				flags |= Flags.VISIBILITY;
				parsed = true;
			}

			// Atmo Pressure
			if ((flags & Flags.ATMO_PRES) == 0 && /^Q[0-9]{4}$/.match(val)) {
				atmo_pressure = new Pressure (val.substring(1).to_double(), Pressure.Unit.HPA);
				flags |= Flags.ATMO_PRES;
				parsed = true;
			}

			if ((flags & Flags.ATMO_PRES) == 0 && /^A[0-9]{4}$/.match(val)) {
				atmo_pressure = new Pressure (val.substring(1).to_double()/100, Pressure.Unit.INHG);
				flags |= Flags.ATMO_PRES;
				parsed = true;
			}

			// Extra informations
			if (parsed == false )
				extras += val; 
		}

		for (int i=0; i<extras.length; i++) {
			string val = extras[i];
			
			if (/^CLR$/.match(val)) {
				sky += "Clear sky.";
				extras[i] = "";
			}

			if (/^((VV|FEW|SCT|BKN|OVC){1}[0-9]{3})|CLR$/.match(val)) {
				sky += val;
				extras[i] = "";
			}
			
			if (/^NOSIG$/.match(val)) {
				extras[i] = "No significant weather change ahead.";
			}
		}

		for (int i=0; i<sky.length; i++) {
			bool matched = false;
			string val = sky[i];
			if (matched == false && val[0:2] == "VV") {
				int t = sky[i].substring(2).to_int()*100;
				sky[i] = @"Vertical visibility $t ft";
				matched = true;
			}

			int t = sky[i].substring(3).to_int()*100;
			switch(val[0:3]) {
				case "CLR":
					sky[i] = "Clear sky - no cloud under 12000 ft";
					matched = true;
					break;
				case "FEW":
					sky[i] = @"Few clouds at $t ft";
					matched = true;
					break;
				case "BKN":
					sky[i] = @"Broken clouds at $t ft";
					matched = true;
					break;
				case "SCT":
					sky[i] = @"Scatter clouds at $t ft";
					matched = true;
					break;
				case "OVC":
					sky[i] = @"Overcast at $t ft";
					matched = true;
					break;
			}
			
			if (matched == false)
				sky[i] = "";
		}
	}
}

class Formatter : Object {
	private DecodedData data;

	public Formatter (DecodedData data) {
		this.data = data;
	}

	public void output () {
		switch (config.output_type) {
			case "general":
				print (@"Location    : %s, %s (%s)\n", GLOBAL[data.short_name].nth_data(3), GLOBAL[data.short_name].nth_data(5), data.short_name);
				print (@"Local time  : %s\n", data.local.format("%F %I:%M %p"));
				print ("Temperature : %.1f %s\n", data.temperature.smart(config.imperial_units), data.temperature.smart_unit(config.imperial_units));
				print ("Dew point   : %.1f %s\n", data.dew_point.smart(config.imperial_units), data.temperature.smart_unit(config.imperial_units));
				print (@"Wind        : $(data.wind.direction) ");
				if (data.wind.has_vary) {
					print (@"($(data.wind.vary1) - $(data.wind.vary2)");
				}
				print ("\nWind Speed  : %.2f kt (%.2f %s)\n", data.wind.speed.get_kt(), data.wind.speed.smart(config.imperial_units), data.wind.speed.smart_unit(config.imperial_units));
				print ("Pressure    : %.1f %s\n", data.atmo_pressure.smart(config.imperial_units), data.atmo_pressure.smart_unit(config.imperial_units));
				print ("Visibility  : %.2f %s\n", data.visibility.human(config.imperial_units), data.visibility.human_unit(config.imperial_units));
				if (data.extras.length != 0) {
					print (@"Extra info  :");
					foreach (var val in data.extras) {
						if (val != "")
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

static Config config;

class Metar : Object {

	public static void abnormal_exit(Error e, string str = "") {
		stderr.printf("Error: %s.\n", e.message);
		stderr.printf(str);
		Posix.exit(1);
	}

	public static int main (string[] args) {

		config = new Config(args);
		var site = new WeatherSite();
		var weather = new DecodedData(site.raw_text);

		// initialize GLOBAL just before output, in case option parsing error.
		GLOBAL = new SiteInfo ();

		//var weather = new DecodedData("RCKH 220330Z 16013G23KT 290V310 3/8SM -SHRA FEW015 BKN035 OVC070 M28/M24 Q1000 TEMPO 1600 SHRA");
		var output = new Formatter(weather);
		output.output();

		return 0;
	}
}
