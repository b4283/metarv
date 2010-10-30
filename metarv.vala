/*
	TODO:
		1. log facility
		2. rrd integration
*/

void println (string? f) {
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
			{ "format", 'f', 0, OptionArg.STRING, ref format_output, "formatted string. use '--format help' for detail.", "<string>" }, 
			{ "imperial", 'i', 0, OptionArg.NONE, ref imperial_units, "use imperial units. (only affect the 'general' output type)", null },
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

		if (format_output != "") {
			output_type = "format";
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
	}

	private void print_format_detail () {
		stdout.printf("Available formatting options:\n\n");
		stdout.printf(" Site infomation:\n");
		stdout.printf("  4-letter name  : %%short_name%%\n");
		stdout.printf("  Full name      : %%full_name%%\n");
		stdout.printf("  Country        : %%country%%\n");
		stdout.printf("  Longtitude     : %%longitude%%\n");
		stdout.printf("  Latitude       : %%latitude%%\n");
		stdout.printf("\n Weather infomation:\n");
		stdout.printf("  Raw metar code : %%raw%%\n");
		stdout.printf("  Local Time     : %%time_<pattern>_end%% (eg: \"%%time_%%F %%R_end%%\", consult `man strftime`)\n");
		stdout.printf("  Temperature    : %%temp_[c | f]%%\n");
		stdout.printf("  Dew point      : %%dew_[c | f]%%\n");
		stdout.printf("  Wind speed     : %%wind_sp_[mps | mph | kt | kmph]\n");
		stdout.printf("  Wind gust      : %%wind_gu_[mps | mph | kt | kmph]\n");
		stdout.printf("  Wind direction : %%wind_dirt%%\n");
		stdout.printf("  Wind variation : %%wind_vary%%\n");
		stdout.printf("  Pressure       : %%pres_[hpa | inhg | bar | psi]%%\n");
		stdout.printf("  Visibility     : %%vis_[imperial | metric]%%\n\n");
		stdout.printf("You have to quote the entire format string, otherwise the program couldn't parse it.\n");
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

			public Speed () {
				is_kt = true;
				speed = 0;
			}

			public void setnum (bool is_kt, double speed) {
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
		public Speed gust;

		public bool has_vary = false;
		public string vary1;
		public string vary2;

		public Wind () {
			speed = new Speed ();
			gust = new Speed ();
		}
		
		public void set_dirt (string dirt) {
			this.direction = dirt;
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
			MILE
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

		public string metric () {
			if (dist > 1000)
				return "%.3g %s".printf(dist/1000, "km");
			else if (dist < 1)
				return "%.0g %s".printf(dist*100, "cm");
			else
				return "%.0g %s".printf(dist, "m");
		}

		public string imperial () {
			if (dist > 1609)
				return "%.3g %s".printf(dist/1609.344, "miles");
			else
				return "%.0g %s".printf(dist*3.2808399, "feet");
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
	}

	public class Pressure : Object {
		public enum Unit {
			HPA, // (Qxxxx)
			INHG // (Axxxx)
		}
		private double num;

		// store as hPa
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

		public double get_bar () {
			return num/1000;
		}

		public double get_psi () {
			return num/68.947573;
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
					wind.gust.setnum (kt, gust);
				wind.speed.setnum (kt, speed); 
				wind.set_dirt (dirt);

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
					f = 0.25; // a quarter mile
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
			if (parsed == false)
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
	private string last_string;

	public Formatter (DecodedData data) {
		this.data = data;
		switch (config.output_type) {
			case "general":
				set_predefined (config.imperial_units);
				parser ();
				break;
			case "format":
				parser ();
				break;
			case "raw":
				last_string = data.raw_code;
				break;
		}
	}

	private void set_predefined (bool imp) {
		var f = new StringBuilder ();
		if (imp) {
			f.append("Location    : %full_name%, %country% (%short_name%)\n");
			f.append("Local time  : %time_%F %I:%M %p_end%\n");
			f.append("Temperature : %temp_f%\n");
			f.append("Dew point   : %dew_f%\n");
			f.append("Wind        : %wind_dirt%");
			if (data.wind.has_vary) {
				f.append(" (%wind_vary%)");
			}
			f.append("\n");
			f.append("Wind Speed  : %wind_sp_kt% (%wind_sp_mph%)\n");
			f.append("Pressure    : %pres_inhg%\n");
			f.append("Visibility  : %vis_imperial%");
//				if (data.extras.length != 0) {
//					print (@"Extra info  :");
//					foreach (var val in data.extras) {
//						if (val != "")
//							print (@" $val");
//					}
//					print ("\n");
		} else {
			f.append("Location    : %full_name%, %country% (%short_name%)\n");
			f.append("Local time  : %time_%F %I:%M %p_end%\n");
			f.append("Temperature : %temp_c%\n");
			f.append("Dew point   : %dew_c%\n");
			f.append("Wind        : %wind_dirt%");
			if (data.wind.has_vary) {
				f.append(" (%wind_vary%)");
			}
			f.append("\n");
			f.append("Wind Speed  : %wind_sp_kt% (%wind_sp_mps%)\n");
			f.append("Pressure    : %pres_hpa%\n");
			f.append("Visibility  : %vis_metric%");
		}
		config.format_output = f.str;
	}

	private void parser () {
		string[] array = config.format_output.split("%");

		bool timed = false;
		for (int i=0; i<array.length; i++) {
			// parse time using glib's datetime
			if (timed == false && array[i].length >= 5 && array[i][0:5] == "time_") {
				string[] temp = { array[i].substring(5) };
				while(true) {
					array[i++] = "";
					if (array[i].length >= 4 && array[i].substring(-4) == "_end") {
						temp += array[i][0:-4];
						break;
					}
					else
						temp += array[i];
				}
				array[i] = data.local.format(string.joinv("%", temp));

				timed = true;
			}

			//
			switch (array[i]) {
				case "raw":
					array[i] = data.raw_code;
					break;
				case "short_name":
					array[i] = data.short_name;
					break;
				case "full_name":
					array[i] = GLOBAL[data.short_name].nth_data(3);
					break;
				case "country":
					array[i] = GLOBAL[data.short_name].nth_data(5);
					break;
				case "latitude":
					array[i] = GLOBAL[data.short_name].nth_data(7);
					break;
				case "longitude":
					array[i] = GLOBAL[data.short_name].nth_data(8);
					break;
				case "vis_metric":
					array[i] = data.visibility.metric();
					break;
				case "vis_imperial":
					array[i] = data.visibility.imperial();
					break;
				case "temp_c":
					array[i] = "%.3g C".printf(data.temperature.celsius());
					break;
				case "temp_f":
					array[i] = "%.3g F".printf(data.temperature.fahrenheit());
					break;
				case "dew_c":
					array[i] = "%.3g C".printf(data.dew_point.celsius());
					break;
				case "dew_f":
					array[i] = "%.3g F".printf(data.dew_point.fahrenheit());
					break;
				case "wind_sp_mps":
					array[i] = "%.3g m/s".printf(data.wind.speed.get_mps());
					break;
				case "wind_sp_mph":
					array[i] = "%.3g mph".printf(data.wind.speed.get_mph());
					break;
				case "wind_sp_kmph":
					array[i] = "%.3g km/h".printf(data.wind.speed.get_kmph());
					break;
				case "wind_sp_kt":
					array[i] = "%.3g knot".printf(data.wind.speed.get_kt());
					break;
				case "wind_gu_mps":
					array[i] = "%.3g m/s".printf(data.wind.gust.get_mps());
					break;
				case "wind_gu_mph":
					array[i] = "%.3g mph".printf(data.wind.gust.get_mph());
					break;
				case "wind_gu_kmph":
					array[i] = "%.3g km/h".printf(data.wind.gust.get_kmph());
					break;
				case "wind_gu_kt":
					array[i] = "%.3g knot".printf(data.wind.gust.get_kt());
					break;
				case "wind_vary":
					if (data.wind.has_vary)
						array[i] = "%s - %s".printf(data.wind.vary1, data.wind.vary2);
					else
						array[i] = "n/a";
					break;
				case "wind_dirt":
					array[i] = "%s".printf(data.wind.direction);
					break;
				case "pres_hpa":
					array[i] = "%.5g hPa".printf(data.atmo_pressure.get_hpa());
					break;
				case "pres_inhg":
					array[i] = "%.4g inHg".printf(data.atmo_pressure.get_inhg());
					break;
				case "pres_bar":
					array[i] = "%.4g bar".printf(data.atmo_pressure.get_bar());
					break;
				case "pres_psi":
					array[i] = "%.4g psi".printf(data.atmo_pressure.get_psi());
					break;
			}
		}
		last_string = string.joinv("", array).compress();
	}

	public void output () {
		print ("%s\n", last_string);
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
// .nth_data(8)  = longitude;
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

		var output = new Formatter(weather);
		output.output();

		return 0;
	}
}
