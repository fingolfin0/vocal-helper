import deimos.portaudio;
import std.conv, std.stdio;
import std.file;
import arsd.terminal;
import std.math.algebraic, std.math.exponential;

import std.string : toStringz;
import core.stdc.locale; // Need setlocale()
import deimos.ncurses;
import core.thread, std.concurrency, std.conv, std.format, std.parallelism;

import std.complex, std.math.rounding, std.algorithm.iteration, core.math, std.math.constants;
import std.numeric; // Преобразование Фурье
import std.range.primitives;

import std.datetime; // Засечь время
import std.range : walkLength; // длина строк

const int ШИРИНА_ФОРМАНТЫ = 4; // в полутонах
const int МАКСИМАЛЬНО_НИЗКОЕ_ВОЗМОЖНОЕ_ПОЛОЖЕНИЕ_ФОРМАНТЫ = 2000; // в герцах
const int МАКСИМАЛЬНО_ВЫСОКОЕ_ВОЗМОЖНОЕ_ПОЛОЖЕНИЕ_ФОРМАНТЫ = 3500; // в герцах

struct PaStreamParameters
{
	/** A valid device index in the range 0 to (Pa_GetDeviceCount()-1)
	 specifying the device to be used or the special constant
	 paUseHostApiSpecificDeviceSpecification which indicates that the actual
	 device(s) to use are specified in hostApiSpecificStreamInfo.
	 This field must not be set to paNoDevice.
	*/
	PaDeviceIndex device;

	/** The number of channels of sound to be delivered to the
	 stream callback or accessed by Pa_ReadStream() or Pa_WriteStream().
	 It can range from 1 to the value of maxInputChannels in the
	 PaDeviceInfo record for the device specified by the device parameter.
	*/
	int channelCount;

	/** The sample format of the buffer provided to the stream callback,
	 a_ReadStream() or Pa_WriteStream(). It may be any of the formats described
	 by the PaSampleFormat enumeration.
	*/
	PaSampleFormat sampleFormat;

	/** The desired latency in seconds. Where practical, implementations should
	 configure their latency based on these parameters, otherwise they may
	 choose the closest viable latency instead. Unless the suggested latency
	 is greater than the absolute upper limit for the device implementations
	 should round the suggestedLatency up to the next practical value - ie to
	 provide an equal or higher latency than suggestedLatency wherever possible.
	 Actual latency values for an open stream may be retrieved using the
	 inputLatency and outputLatency fields of the PaStreamInfo structure
	 returned by Pa_GetStreamInfo().
	 @see default*Latency in PaDeviceInfo, *Latency in PaStreamInfo
	*/
	PaTime suggestedLatency;

	/** An optional pointer to a host api specific data structure
	 containing additional information for device setup and/or stream processing.
	 hostApiSpecificStreamInfo is never required for correct operation,
	 if not used it should be set to NULL.
	*/
	void *hostApiSpecificStreamInfo;

};


class Сглаживатель {
	public:
		this(float[] веса ...) {
			данные = new Msg[веса.length];
			коэффициенты = new float[веса.length];
			float множитель = 1 / веса.sum;
			foreach(i, вес; веса)
				this.коэффициенты[i] = вес * множитель;
		}
		Msg обновить(Msg новые_данные) {
			// сместить все элементы, что бы новое сообщение поместить в последний индекс
			foreach(i; 0..данные.length-1)
				данные[i] = данные[i+1];
			// добавить новое сообщение
			данные[$-1] = новые_данные;
			
			Msg сглажданные;
			foreach(i; 0..данные.length)
				сглажданные += данные[i] * коэффициенты[i];
			return сглажданные;
		}
	public:
		Msg[] данные;
		float[] коэффициенты;
}
struct ЗатраченноеВремя {
	Duration общее = dur!"seconds"(0);
	long количество_периодов = 0;
	void добавить(Duration продолжительность) {
		общее += продолжительность;
		количество_периодов ++;
	}
	Duration среднее() { return общее / количество_периодов; }
}
struct ЗатраченныеТакты {
	ulong общее = 0;
	long количество_периодов = 0;
	void добавить(long такты) {
		общее += такты;
		количество_периодов ++;
	}
	long среднее() { return cast(long)round(cast(double)общее / количество_периодов); }
}
struct КолбэкДанные
{
	float[] audio;
	int count=0;
	float громкость=0;
	Tid поток;
	float[] спектр;
	int МАКС_ФОРМАНТА, МИН_ФОРМАНТА;
	float МНОЖ_ФОРМАНТЫ;
	float ЧАСТОТА_ДИСКРЕТИЗАЦИИ;
	ЗатраченныеТакты тактыПреобразованияФурье;
	float[] окно;
}
struct Msg {
	float громкость = 0;
	float звонкость = 0; // в процентах
	float положение_форманты = 0; // в герцах
	float тактыФурье = 0;
	float тактыФорманты = 0;
	//Duration время;
	Msg opBinary(string op)(Msg сообщение) {
		Msg новсообщение;
		if(op == "+") {
			новсообщение.громкость = this.громкость + сообщение.громкость;
			новсообщение.звонкость = this.звонкость + сообщение.звонкость;
			новсообщение.положение_форманты = this.положение_форманты + сообщение.положение_форманты;
			новсообщение.тактыФурье = this.тактыФурье + сообщение.тактыФурье;
			новсообщение.тактыФорманты = this.тактыФорманты + сообщение.тактыФорманты;
		} else if(op == "-") {
			новсообщение.громкость = this.громкость - сообщение.громкость;
			новсообщение.звонкость = this.звонкость - сообщение.звонкость;
			новсообщение.положение_форманты = this.положение_форманты - сообщение.положение_форманты;
			новсообщение.тактыФурье = this.тактыФурье - сообщение.тактыФурье;
			новсообщение.тактыФорманты = this.тактыФорманты - сообщение.тактыФорманты;
		}
		return новсообщение;
	}
	Msg opBinary(string op)(float множитель) {
		Msg новсообщение;
		if(op == "*") {
			новсообщение.громкость = this.громкость * множитель;
			новсообщение.звонкость = this.звонкость * множитель;
			новсообщение.положение_форманты = this.положение_форманты * множитель;
			новсообщение.тактыФурье = this.тактыФурье * множитель;
			новсообщение.тактыФорманты = this.тактыФорманты * множитель;
		}
		return новсообщение;
	}
	ref Msg opOpAssign(string op)(Msg сообщение) {
		if (op == "+") {
			громкость += сообщение.громкость;
			звонкость += сообщение.звонкость;
			положение_форманты += сообщение.положение_форманты;
			тактыФурье += сообщение.тактыФурье;
			тактыФорманты += сообщение.тактыФорманты;
		} else if (op == "-") {
			громкость -= сообщение.громкость;
			звонкость -= сообщение.звонкость;
			положение_форманты -= сообщение.положение_форманты;
			тактыФурье -= сообщение.тактыФурье;
			тактыФорманты -= сообщение.тактыФорманты;
		}
		return this;
	}
}
struct АудиоДиапазон {
	float* буфер;
	size_t размер;
	
	@property bool empty() const {
		return размер == 0;
	}
	@property size_t length() const {
		return размер;
	}
	@property АудиоДиапазон save() {
		return this;
	}
	float opIndex(size_t индекс) const {
		return *(буфер + индекс);
	}
	
	@property float front() const {
		return opIndex(0);
	}
	@property float back() const {
		return opIndex(размер - 1);
	}
	void popFront() {
		++буфер;
		--размер;
	}
	void popBack() {
		--размер;
	}
}

long засечьТакты() {
	asm {
		naked;
		rdtsc;
		ret;
	}
}

float[] породитьОкно(int размер) {
	float[] окно = new float[размер];
	// Генерация окна Блэкмана (https://ru.wikipedia.org/wiki/Оконное_преобразование_Фурье#Окно_Блэкмана)
	// w(n) = a0 - a1*cos(2*pi*n/(N-1)) + a2*cos(4*pi*n/(N-1))
	// второй множитель получаю через формулу косинуса двойного угла
	// множители а_[0-2] меняю соответственно
	immutable float α = 0.16;
	immutable float a0 = 1 / 2 - α;
	immutable float a1 = 1 / 2;
	immutable float a2 = α;
	immutable float множитель_аргумента = 2 * PI / (размер - 1);
	
	foreach(n; 0 .. размер) {
		float множитель = cos(множитель_аргумента * n);
		окно[n] = a0 - a1 * множитель + a2 * множитель^^2;
	}
	/*
	// сделать прямоугольное окно
	foreach(n; 0 .. размер)
		окно[n] = 1;
	*/
	return окно;
}

extern(C) int sawtooth(const(void)* inputBuffer, void* outputBuffer,
                             size_t framesPerBuffer,
                             const(PaStreamCallbackTimeInfo)* timeInfo,
                             PaStreamCallbackFlags statusFlags,
                             void *userData)
{
	long начальныйТакт = засечьТакты();
	//SysTime начальноеВремя = Clock.currTime();
    auto колбэк_данные = cast(КолбэкДанные*)userData;

    auto pout = cast(float*)outputBuffer;
    auto pin = cast(float*)inputBuffer;
    
    float сумма = 0;
    
    float[] сигнал = new float[framesPerBuffer];
	foreach(i; 0 .. framesPerBuffer) {
		//колбэк_данные.audio ~= *pin++;
		//колбэк_данные.audio ~= *pin++;
		сигнал[i] = *pin;
		сумма += (*pin++)^^2;
	}
	
	float средняяГромкость = 20*log(core.math.sqrt(сумма/framesPerBuffer));
	
	//Не работает (нет слайсинга):
	//auto аудиоДиапазон = АудиоДиапазон(cast(float*)inputBuffer, framesPerBuffer);
	// умножаю сигнал на окно
	foreach(i; 0 .. сигнал.length)
		сигнал[i] *= колбэк_данные.окно[i];
	auto спектрКомплексный = fft!(float, float[])(сигнал);
	int размер_спектра = cast(int)framesPerBuffer / 2;
	// Массив для спектра на единицу больше, что бы нумеровать индексы с единицы,
	// что бы было удобнее потом переводить индекс в частоту
	float[] спектр = new float[размер_спектра+1];
	спектр[0] = 0;
	foreach(i; 1..размер_спектра+1)
		спектр[i]=abs(спектрКомплексный[i]);
	long фурьеТакт = засечьТакты();
	колбэк_данные.спектр = спектр;
	
	float МНОЖ_ФОРМАНТЫ = колбэк_данные.МНОЖ_ФОРМАНТЫ;
	float МНОЖ_Ф_ПОЛ = core.math.sqrt(МНОЖ_ФОРМАНТЫ);
	// множитель для получения индекса из частоты:
	float МНОЖ_ИНДЕКСА = cast(float)framesPerBuffer / колбэк_данные.ЧАСТОТА_ДИСКРЕТИЗАЦИИ;
	// множитель для обратного преобразования:
	float МНОЖ_ЧАСТОТЫ = 1 / МНОЖ_ИНДЕКСА;
	

	// Инициализация алгоритма, подсчёт показателей самой низкой форманты
	// ------------------------------------------------------------------
	int НАЧАЛЬНЫЙ_ИНДЕКС = cast(int)round(колбэк_данные.МИН_ФОРМАНТА / МНОЖ_Ф_ПОЛ * МНОЖ_ИНДЕКСА);
	int КОНЕЧНЫЙ_ИНДЕКС = cast(int)round(колбэк_данные.МАКС_ФОРМАНТА / МНОЖ_Ф_ПОЛ * МНОЖ_ИНДЕКСА);
	// Верхняя граница форманты (индекс)
	int предыдущий_верх;
	int верх = cast(int)round(НАЧАЛЬНЫЙ_ИНДЕКС * МНОЖ_ФОРМАНТЫ);
	float ЭНЕРГИЯ_СИГНАЛА = 0;
	foreach(j; 0 .. спектр.length)
		ЭНЕРГИЯ_СИГНАЛА += спектр[j]^^2;
	ЭНЕРГИЯ_СИГНАЛА = core.math.sqrt(ЭНЕРГИЯ_СИГНАЛА);
	//ЭНЕРГИЯ_СИГНАЛА = sum(спектр[0..$]);
	float энергия_форманты = 0;
	foreach(отсчёт; спектр[НАЧАЛЬНЫЙ_ИНДЕКС .. верх+1])
		энергия_форманты += отсчёт^^2;
	/*foreach(i; НАЧАЛЬНЫЙ_ИНДЕКС .. верх+1)
		энергия_форманты += спектр[i];*/
	//энергия_форманты = sum(спектр[НАЧАЛЬНЫЙ_ИНДЕКС .. верх+1]);
	float макс_энергия_форманты = энергия_форманты;
	float положение_форманты = колбэк_данные.МИН_ФОРМАНТА;
	
	
	// Итерирование, проход по всем возможным формантам. Лучший вариант за-
	// писывается в переменные "макс_энергия_форманты" и "положение_форманты"
	// --------------------------------------------------------------------
	foreach(i; НАЧАЛЬНЫЙ_ИНДЕКС+1 .. КОНЕЧНЫЙ_ИНДЕКС+1) {
		// Убираем из суммы форманты первый индекс, потом добавляем последий/е
		энергия_форманты -= спектр[i-1]^^2;
		//энергия_форманты -= спектр[i-1];
		предыдущий_верх = верх;
		верх = cast(int)round(i * МНОЖ_ФОРМАНТЫ);
		foreach(j; предыдущий_верх+1 .. верх+1)
			энергия_форманты += спектр[j]^^2;
		//энергия_форманты += sum(спектр[предыдущий_верх+1..верх+1]);
		// Проверяем, лучше ли эта форманта, чем текущая максимальная
		if (энергия_форманты > макс_энергия_форманты) {
			макс_энергия_форманты = энергия_форманты;
			положение_форманты = i * МНОЖ_ЧАСТОТЫ * МНОЖ_Ф_ПОЛ;
		}
	}
	
	long формантаТакт = засечьТакты();
	//SysTime конечноеВремя = Clock.currTime();
	колбэк_данные.поток.send(Msg(
		средняяГромкость,
		core.math.sqrt(макс_энергия_форманты) / ЭНЕРГИЯ_СИГНАЛА * 100,
		//макс_энергия_форманты / ЭНЕРГИЯ_СИГНАЛА * 100,
		положение_форманты,
		фурьеТакт - начальныйТакт,
		формантаТакт - фурьеТакт,
		//конечноеВремя - начальноеВремя
	));
	
	scope(failure) endwin();
    return 0;
}


int main() {
    PaError err;
    if ((err = Pa_Initialize()) != paNoError) myerror(err);
    
	auto numDevices = Pa_GetDeviceCount();
	if( numDevices < 0 ) {
		writeln( "ERROR: Pa_CountDevices returned ", numDevices );
		err = numDevices;
		myerror(err);
	}
	int[] микрофоны;
	foreach(i; 0 .. numDevices)
		if(Pa_GetDeviceInfo(i).maxInputChannels > 0)
			микрофоны ~= i;
	foreach(i; 0 .. микрофоны.length) {
		auto инфо = Pa_GetDeviceInfo(микрофоны[i]);
		writeln(i, " - ", to!string(инфо.name), ":");
		writeln("Вход: ", инфо.maxInputChannels, ", выход: ", инфо.maxOutputChannels, ", индекс API: ", инфо.hostApi, ".");
		writeln("");
	}
	
	int пользвыбор;
	readf!"%d\n"(пользвыбор);
	/*
	auto пользввод = readln();
	int пользвыбор = to!int(пользввод);
	*/
	/*
	writeln(пользвыбор);
	readln();
	*/
	//goto exit;
	
	//File file = File("audio.raw", "w");	
	void[] buf;
	//auto terminal = Terminal(ConsoleOutputType.linear);
	//auto input = RealTimeConsoleInput(&terminal, ConsoleInputFlags.raw);

    enum SAMPLE_RATE = 44100;
    enum NUM_SECONDS = 3;
    immutable РАЗМЕР_БУФЕРА = 2048;

    PaStream* stream;
    КолбэкДанные колбэк_данные;
	колбэк_данные.поток = thisTid;
	колбэк_данные.МИН_ФОРМАНТА = МАКСИМАЛЬНО_НИЗКОЕ_ВОЗМОЖНОЕ_ПОЛОЖЕНИЕ_ФОРМАНТЫ;
	колбэк_данные.МАКС_ФОРМАНТА = МАКСИМАЛЬНО_ВЫСОКОЕ_ВОЗМОЖНОЕ_ПОЛОЖЕНИЕ_ФОРМАНТЫ;
	колбэк_данные.МНОЖ_ФОРМАНТЫ = 2^^(ШИРИНА_ФОРМАНТЫ/12.0);
	колбэк_данные.ЧАСТОТА_ДИСКРЕТИЗАЦИИ = SAMPLE_RATE;
	колбэк_данные.окно = породитьОкно(РАЗМЕР_БУФЕРА);

	ЗатраченноеВремя времяНаОтрисовку;
	
	//PaStreamParameters test;
	/*
	deimos.portaudio.PaStreamParameters* вхоПарам, выхПарам;
	вхоПарам.channelCount = 1;
	вхоПарам.device = пользвыбор;
	вхоПарам.hostApiSpecificStreamInfo = null;
	вхоПарам.sampleFormat = paFloat32;
	вхоПарам.suggestedLatency = Pa_GetDeviceInfo(пользвыбор).defaultLowInputLatency;
	вхоПарам.hostApiSpecificStreamInfo = null;
	const deimos.portaudio.PaStreamParameters* вхоПарамСсыл = вхоПарам;
	const deimos.portaudio.PaStreamParameters* выхПарамСсыл = выхПарам;
	err = Pa_IsFormatSupported( вхоПарамСсыл, выхПарамСсыл, 44100 );
	
	if( err == paFormatIsSupported )
	{
	writeln( "Hooray!\n");
	}
	else
	{
	writeln("Too Bad.\n");
	}
	/*
	if ((err = Pa_OpenDefaultStream(&stream,
                                    1,
                                    0,
                                    paFloat32,
                                    SAMPLE_RATE,
                                    РАЗМЕР_БУФЕРА,
                                    &sawtooth,
                                    &колбэк_данные))
        != paNoError) myerror(err);
        */
	/*
	*/
	
	
	
    if ((err = Pa_OpenDefaultStream(&stream,
                                    1,
                                    0,
                                    paFloat32,
                                    SAMPLE_RATE,
                                    РАЗМЕР_БУФЕРА,
                                    &sawtooth,
                                    &колбэк_данные))
        != paNoError) myerror(err);
        

    if ((err = Pa_StartStream(stream)) != paNoError) myerror(err);
    //Pa_Sleep(NUM_SECONDS * 1000);

	setlocale(LC_CTYPE,"");
	initscr();     // initialize the screen
	scope (exit)
        endwin();
	noecho(); // убрать отображение вводимого символа при выходе
	curs_set(0); // спрятать курсор
	if(has_colors()) { start_color(); } // включаю поддержку цветов
	init_pair(1, COLOR_RED, COLOR_BLACK);
	init_pair(2, COLOR_YELLOW, COLOR_BLACK);
	init_pair(3, COLOR_GREEN, COLOR_BLACK);
	immutable int[string] СТРОКИ = [
		"громкость" : 0,
		"звонкость" : 2,
		"режим звонкости" : 3,
		"позиция" : 7,
	];
	
	immutable int[4] УРОВНИ_ФОРМАНТЫ_МУЖСКИЕ = [0, 17, 35, 70];
	immutable int[4] УРОВНИ_ФОРМАНТЫ_ЖЕНСКИЕ = [0, 12, 25, 50];
	string режим_шкалы = "женский";
	int[4] УРОВНИ_ФОРМАНТЫ;
	auto ввод = task!getch();
	void сменить_режим_окрашивания() {
		if(режим_шкалы == "мужской") {
			режим_шкалы = "женский";
			УРОВНИ_ФОРМАНТЫ = УРОВНИ_ФОРМАНТЫ_ЖЕНСКИЕ;
			mvwprintw(stdscr, СТРОКИ["режим звонкости"], 0, toStringz("Режим шкалы: женский голос. Для смены режима нажмите 'р'."));
		} else {
			режим_шкалы = "мужской";
			УРОВНИ_ФОРМАНТЫ = УРОВНИ_ФОРМАНТЫ_МУЖСКИЕ;
			mvwprintw(stdscr, СТРОКИ["режим звонкости"], 0, toStringz("Режим шкалы: мужской голос. Для смены режима нажмите 'р'."));
		}
	}
	сменить_режим_окрашивания(); // вызываю, что бы отрисовать интерфейс
	//int j=10;
	bool обработать_ввод() {
		if(ввод.done) {
			//mvwprintw(stdscr, j++, 0, toStringz(to!string(ввод.yieldForce())));
			switch(ввод.yieldForce()) {
				case 27:
					return true;
				case 104:
				case 183:
				case 112:
				case 128:
					сменить_режим_окрашивания();
					break;
				default:
					break;
			}
			ввод.executeInNewThread();
		}
		return false;
	}
	ввод.executeInNewThread();
	
	auto сглаживатель = new Сглаживатель(10, 6, 5, 4, 3, 3, 2, 2, 1, 1);
	//auto сглаживатель = new Сглаживатель(1);
	
	int row, col;
    getmaxyx(stdscr, row, col); 
    
	mvwprintw(stdscr, СТРОКИ["громкость"], 0, toStringz("Громкость:"));
	mvwprintw(stdscr, СТРОКИ["звонкость"], 0, toStringz("Звонкость:"));
	mvwprintw(stdscr, СТРОКИ["позиция"], 0, toStringz("Положение форманты:"));
	
	mvwprintw(stdscr, row-1, 0, toStringz("Для выхода нажмите <Esc>."));
	//int i = 0;
	immutable float МинГромкость = -100, МаксГромкость = 0;
	immutable float ДиапазонГромкости = МаксГромкость - МинГромкость;
	immutable int НачалоШкалы = 18+6+4;
	immutable int МестоДляШкалы = col-НачалоШкалы;
	отрисовать_указатели_типов_голосов(СТРОКИ["позиция"], НачалоШкалы, МестоДляШкалы-1, МАКСИМАЛЬНО_НИЗКОЕ_ВОЗМОЖНОЕ_ПОЛОЖЕНИЕ_ФОРМАНТЫ, МАКСИМАЛЬНО_ВЫСОКОЕ_ВОЗМОЖНОЕ_ПОЛОЖЕНИЕ_ФОРМАНТЫ);
	wchar[] шкала = new wchar[МестоДляШкалы];
	while (true) {
	//foreach (i; 3 .. 100) {
		//Msg показатели = receiveOnly!Msg();
		Msg показатели = сглаживатель.обновить(receiveOnly!Msg());
		SysTime времяНачалаОтрисовки = Clock.currTime();
		
		auto громкость = показатели.громкость;
		
		
		float доля_громкости = (громкость - МинГромкость)/ДиапазонГромкости;
		if (доля_громкости < 0) { доля_громкости = 0; }
		int количество_звёздочек;
		количество_звёздочек = cast(int)(МестоДляШкалы*доля_громкости);
		foreach(i; 0 .. количество_звёздочек) { шкала[i] = '■'; }
		foreach(i; количество_звёздочек .. МестоДляШкалы) { шкала[i] = '-'; }
		
		mvwprintw(stdscr, СТРОКИ["громкость"], 18, toStringz(format("%6.0f Дб %s", громкость, шкала)));
		mvwprintw(stdscr, СТРОКИ["звонкость"], 18, toStringz(format("%6.0f %%%%", показатели.звонкость)));
		
		/*
		mvwprintw(stdscr, row-3, 0, toStringz(format(
			"Тактов на вычисление Фурье:  %6.0f, при тактовой частоте 4 ГГц это %3.0f мкс.     ",
			cast(int)round(показатели.тактыФурье),
			cast(int)round(показатели.тактыФурье / 4000.0)
		)));
		mvwprintw(stdscr, row-2, 0, toStringz(format(
			"Тактов на вычисления Форманты:  %4.0f, при тактовой частоте 4 ГГц это %3.0f мкс.     ",
			cast(int)round(показатели.тактыФорманты),
			cast(int)round(показатели.тактыФорманты / 4000.0)
		)));
		*/
		
		
		количество_звёздочек = cast(int)round(МестоДляШкалы * cast(float)показатели.звонкость / cast(float)УРОВНИ_ФОРМАНТЫ[3]);
		bool зашкаливание = false;
		if (количество_звёздочек > МестоДляШкалы) {
			количество_звёздочек = МестоДляШкалы;
			зашкаливание = true;
		}
		//foreach(i; 0 .. количество_звёздочек) { шкала[i] = '■'; }
		//foreach(i; количество_звёздочек .. МестоДляШкалы) { шкала[i] = '-'; }
		foreach(i; 0 .. МестоДляШкалы) { шкала[i] = '-'; }
		mvwprintw(stdscr, СТРОКИ["звонкость"], НачалоШкалы, toStringz(format("%s", шкала)));
		mvwprintw(stdscr, СТРОКИ["позиция"], НачалоШкалы, toStringz(format("%s", шкала)));
		wchar[] звёздочки = new wchar[количество_звёздочек];
		foreach(i; 0 .. количество_звёздочек) { звёздочки[i] = '■'; }
		int цветовая_пара;
		if(показатели.звонкость < УРОВНИ_ФОРМАНТЫ[1]) {
			цветовая_пара = 1;
			mvwprintw(stdscr, СТРОКИ["позиция"], 19, toStringz(" (нет)  "));
		} else { 
			if(показатели.звонкость < УРОВНИ_ФОРМАНТЫ[2])
				цветовая_пара = 2;
			else
				цветовая_пара = 3;
			mvwprintw(stdscr,СТРОКИ["позиция"], 19, toStringz(format("%5d Гц", cast(int)round(показатели.положение_форманты))));
		}
		
		attron(COLOR_PAIR(цветовая_пара));
		mvwprintw(stdscr, СТРОКИ["звонкость"], НачалоШкалы, toStringz(format("%s", звёздочки)));
		if(зашкаливание) {
			цветовая_пара = 1;
			attron(COLOR_PAIR(цветовая_пара));
			mvwprintw(stdscr, СТРОКИ["звонкость"], col-1, toStringz("■"));
		}
		attroff(COLOR_PAIR(цветовая_пара));
		
		
		if(показатели.звонкость >= УРОВНИ_ФОРМАНТЫ[1]) {
			int позиция = cast(int)round(cast(float)(МестоДляШкалы - 1) / (МАКСИМАЛЬНО_ВЫСОКОЕ_ВОЗМОЖНОЕ_ПОЛОЖЕНИЕ_ФОРМАНТЫ - МАКСИМАЛЬНО_НИЗКОЕ_ВОЗМОЖНОЕ_ПОЛОЖЕНИЕ_ФОРМАНТЫ) * (показатели.положение_форманты - МАКСИМАЛЬНО_НИЗКОЕ_ВОЗМОЖНОЕ_ПОЛОЖЕНИЕ_ФОРМАНТЫ)) + НачалоШкалы;
			mvwprintw(stdscr, СТРОКИ["позиция"], позиция, toStringz("◆"));
		}
		
		
		refresh();
		
		времяНаОтрисовку.добавить(Clock.currTime() - времяНачалаОтрисовки);
		//int ch = ERR;
		//int ch = getch();
		//if(ch != ERR) { break; }
		if(обработать_ввод()) { break; }
	}
	
	
	endwin();
	
	File file = File("data", "w");
	//writeln(колбэк_данные.спектр);
	foreach(i; 0..колбэк_данные.спектр.length)
		file.writeln(колбэк_данные.спектр[i]);
	file.close();
	
	writeln("Общее время, затраченное на отрисовку: ", времяНаОтрисовку.общее);
	writeln("Среднее время на отрисовку одного периода: ", времяНаОтрисовку.среднее);
		
	if ((err = Pa_StopStream(stream)) != paNoError) myerror(err);
	if ((err = Pa_CloseStream(stream)) != paNoError) myerror(err);
	if ((err = Pa_Terminate()) != paNoError) myerror(err);
	
    
	//file.rawWrite(phase_data.audio);
	//Thread.sleep(dur!"seconds"(10));
	exit:
    return 0;
}


void отрисовать_указатели_типов_голосов(int строка, int нач_стлб, int место, int МИН_ФОРМАНТА, int МАКС_ФОРМАНТА) {
	
	enum тип_голоса { бас, баритон, тенор, контральто, меццосопрано, сопрано, хак };
	enum : тип_голоса {
		бас = тип_голоса.бас,
		баритон = тип_голоса.баритон,
		тенор = тип_голоса.тенор,
		контральто = тип_голоса.контральто,
		меццосопрано = тип_голоса.меццосопрано,
		сопрано = тип_голоса.сопрано
	}
	enum точка { низ, середина, верх };
	enum : точка {
		низ = точка.низ,
		середина = точка.середина,
		верх = точка.верх
	}
	
	int[точка][тип_голоса] ГРАНИЦА;
	ГРАНИЦА[бас] = [ низ : 2200, верх : 2500 ];
	ГРАНИЦА[баритон] = [ низ : 2350, верх : 2650 ];
	ГРАНИЦА[тенор] = [ низ : 2500, верх : 2800 ];
	ГРАНИЦА[контральто] = [ низ : 2650, верх : 2950 ];
	ГРАНИЦА[меццосопрано] = [ низ : 2800, верх : 3100 ];
	ГРАНИЦА[сопрано] = [ низ : 2950, верх : 3250 ];
	
	int позиционировать(float точка) {
		float доля = (cast(float)точка - cast(float)МИН_ФОРМАНТА) / (cast(float)МАКС_ФОРМАНТА - cast(float)МИН_ФОРМАНТА);
		return нач_стлб + cast(int)round(доля * место);
	}
	
	int[точка][тип_голоса] ПОЗИЦИЯ;
	foreach(i; тип_голоса.min .. тип_голоса.max)
		ПОЗИЦИЯ[i] = [
			низ : позиционировать(ГРАНИЦА[i][низ]),
			верх : позиционировать(ГРАНИЦА[i][верх]),
			середина : позиционировать((ГРАНИЦА[i][низ] + ГРАНИЦА[i][верх]) / 2.0)
		];
	void рисовать_скобку(int строка, int нач_стлб, int кон_стлб, bool верхняя) {
		mvwprintw(stdscr, строка, нач_стлб, toStringz(верхняя?"┌":"└"));
		mvwprintw(stdscr, строка, кон_стлб, toStringz(верхняя?"┐":"┘"));
		foreach(i; нач_стлб+1 .. кон_стлб)
			mvwprintw(stdscr, строка, i, toStringz("─"));
	}
	void рисовать_название(int строка, int стлб, string название) {
		mvwprintw(stdscr, строка, cast(int)round(стлб - название.walkLength/2.0), toStringz(название));
	}
	
	foreach(i; [бас, тенор, меццосопрано]) {
		рисовать_скобку(строка - 1, ПОЗИЦИЯ[i][низ], ПОЗИЦИЯ[i][верх], true);
		рисовать_название(строка - 2, ПОЗИЦИЯ[i][середина], to!string(i));
	}
	foreach(i; [баритон, контральто, сопрано]) {
		рисовать_скобку(строка + 1, ПОЗИЦИЯ[i][низ], ПОЗИЦИЯ[i][верх], false);
		рисовать_название(строка + 2, ПОЗИЦИЯ[i][середина], to!string(i));
	}
	
	if(ПОЗИЦИЯ[бас][верх] == ПОЗИЦИЯ[тенор][низ])
		mvwprintw(stdscr, строка - 1, ПОЗИЦИЯ[бас][верх], toStringz("┬"));
	if(ПОЗИЦИЯ[тенор][верх] == ПОЗИЦИЯ[меццосопрано][низ])
		mvwprintw(stdscr, строка - 1, ПОЗИЦИЯ[тенор][верх], toStringz("┬"));
	if(ПОЗИЦИЯ[баритон][верх] == ПОЗИЦИЯ[контральто][низ])
		mvwprintw(stdscr, строка + 1, ПОЗИЦИЯ[баритон][верх], toStringz("┴"));
	if(ПОЗИЦИЯ[контральто][верх] == ПОЗИЦИЯ[сопрано][низ])
		mvwprintw(stdscr, строка + 1, ПОЗИЦИЯ[контральто][верх], toStringz("┴"));
}

int myerror(PaError err) {
	stderr.writefln("error %s", to!string(Pa_GetErrorText(err)));
	return(1);
}
