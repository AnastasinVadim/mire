#!/usr/bin/env swipl

:- initialization(main, main).
:- use_module(library(socket)).
:- use_module(library(random)).
:- use_module(library(thread)).
:- dynamic server_messages/1.
:- dynamic room_description/2.
:- dynamic room_exits/2.
:- dynamic edge/3.
:- dynamic current_room_id/1.
:- dynamic next_room_index/1.
:- dynamic opposite_dir/2.

% Противоположные направления
opposite_dir(north, south).
opposite_dir(south, north).
opposite_dir(east, west).
opposite_dir(west, east).

main :-
    sleep(5),
    client(localhost, 3333).

client(Host, Port) :-
    setup_call_cleanup(
        tcp_connect(Host:Port, Stream, []),
        (   thread_create(reader_thread(Stream), _, [detached(true)]),
            bot(Stream)
        ),
        close(Stream)
    ).

% Инициализация хранилища сообщений
:- assertz(server_messages([])).

reader_thread(Stream) :-
    repeat,
    (   read_line_to_string(Stream, Line),
        (   Line == end_of_file
        ->  true, !
        ;   retract(server_messages(Current)),
            append(Current, [Line], New),
            assertz(server_messages(New)),
            fail
        )
    ).

get_server_messages(Messages) :-
    server_messages(Messages).

get_last_message(Last) :-
    server_messages(Messages),
    (   Messages = [] -> Last = "";
        last(Messages, Last)
    ).

clear_server_messages :-
    retractall(server_messages(_)),
    assertz(server_messages([])).

send_command(Stream, Command, Response) :-
    clear_server_messages,
    format(Stream, '~s~n', [Command]),
    flush_output(Stream),
    sleep(1),
    get_server_messages(Messages),
    atomics_to_string(Messages, "\n", Response).

% Инициализация базы данных карты
init_map_db :-
    retractall(room_description(_, _)),
    retractall(room_exits(_, _)),
    retractall(edge(_, _, _)),
    retractall(current_room_id(_)),
    retractall(next_room_index(_)),
    assertz(next_room_index(1)).

% Обновить информацию о комнате (не перезаписывает выходы для известных комнат)
update_room(Description, Exits) :-
    (   room_description(Id, Description)
    ->  true % Для известных комнат сохраняем существующие выходы
    ;   next_room_index(Id),
        retract(next_room_index(Id)),
        NewId is Id + 1,
        assertz(next_room_index(NewId)),
        assertz(room_description(Id, Description)),
        assertz(room_exits(Id, Exits)) % Только для новых комнат
    ),
    retractall(current_room_id(_)),
    assertz(current_room_id(Id)).

parse_look(Response, Description, Exits) :-
    split_string(Response, "\n", "", Lines),
    find_first_non_empty(Lines, Description),
    find_exits_line(Lines, ExitsLine),
    extract_exits(ExitsLine, Exits).

find_first_non_empty([], "").
find_first_non_empty([Line|Lines], First) :-
    (   string_length(Line, 0)
    ->  find_first_non_empty(Lines, First)
    ;   First = Line
    ).

find_exits_line([], "").
find_exits_line([Line|Lines], ExitsLine) :-
    (   sub_string(Line, 0, 6, _, "Exits:")
    ->  ExitsLine = Line
    ;   find_exits_line(Lines, ExitsLine)
    ).

extract_exits(ExitsLine, Exits) :-
    (   sub_string(ExitsLine, 7, _, 0, ExitsStr)
    ->  split_string(ExitsStr, ",", "", ExitParts),
        parse_exit_parts(ExitParts, Exits)
    ;   Exits = []
    ).

parse_exit_parts([], []).
parse_exit_parts([Part|Rest], [Dir|Exits]) :-
    string_trim(Part, Trimmed),
    (   member(DirStr, ["north", "south", "east", "west"]),
        sub_string(Trimmed, 0, _, _, DirStr)
    ->  atom_string(Dir, DirStr),
        parse_exit_parts(Rest, Exits)
    ;   parse_exit_parts(Rest, Exits)
    ).

string_trim(String, Trimmed) :-
    string_chars(String, Chars),
    trim(Chars, TrimmedChars),
    string_chars(Trimmed, TrimmedChars).

trim([], []).
trim([' '|T], R) :- trim(T, R).
trim([H|T], [H|R]) :- H \= ' ', trim_back(T, R).

trim_back([], []).
trim_back(L, R) :- reverse(L, Rev), trim(Rev, RevTrimmed), reverse(RevTrimmed, R).

% Проверка, все ли комнаты полностью исследованы
all_rooms_explored :-
    \+ ( room_description(Id, _),
         room_exits(Id, Exits),
         member(Dir, Exits),
         \+ edge(Id, Dir, _)
    ).

% Обработка успешного перемещения
process_successful_move(Stream, MoveResponse, Dir, FromId) :-
    (   parse_look(MoveResponse, NewDesc, NewExits)
    ->  update_room(NewDesc, NewExits),
        current_room_id(NewId),
        (   edge(FromId, Dir, NewId)
        ->  true
        ;   opposite_dir(Dir, OppDir),
            assertz(edge(FromId, Dir, NewId)),
            assertz(edge(NewId, OppDir, FromId))
        ),
        format('Moved: ~w -> ~w via ~w~n', [FromId, NewId, Dir]),
        sleep(5)
    ;   format('Failed to parse look after move~n', [])
    ).

% Отправка команды перемещения и обработка ответа
move(Stream, Dir, Result) :-
    format(atom(Command), "move ~w", [Dir]),
    send_command(Stream, Command, Response),
    (   Response = "You can't go that way."
    ->  Result = false
    ;   Result = Response
    ).

% Основной цикл бота со случайным перемещением
bot_loop(Stream) :-
    % Проверяем условие завершения
    (   all_rooms_explored
    ->  writeln('LOG: All routes explored. Exiting.'),
        true
    ;   % Получаем текущую комнату
        current_room_id(CurrentId),
        
        % Получаем все возможные выходы
        room_exits(CurrentId, ExitsList),
        
        % Если выходов нет - завершаем
        (   ExitsList = []
        ->  writeln('LOG: Stuck in dead end. Exiting.'),
            true
        ;   % Случайный выбор направления из всех доступных выходов
            random_member(Dir, ExitsList),
            
            % Пытаемся переместиться
            move(Stream, Dir, MoveResult),
            
            % Обработка результата перемещения
            (   MoveResult = false
            ->  % Удаляем непроходимый выход
                retract(room_exits(CurrentId, CurrentList)),
                delete(CurrentList, Dir, NewList),
                assertz(room_exits(CurrentId, NewList)),
                writeln(fmt('Removed blocked exit: ~w', [Dir])),
                
                % Повторяем цикл в той же комнате
                bot_loop(Stream)
            ;   % Успешное перемещение - обновляем карту
                process_successful_move(Stream, MoveResult, Dir, CurrentId),
                
                % Продолжаем исследование
                bot_loop(Stream)
            )
        )
    ).

% Главная функция бота
bot(Stream) :-
    % Регистрация
    format(Stream,'~s~n',["bot"]),
    flush_output(Stream),
    sleep(2),
    clear_server_messages(),
    
    % Инициализация карты
    init_map_db,
    
    % Первичный осмотр (look)
    send_command(Stream, "look", ResponseLook),
    (   parse_look(ResponseLook, Desc, Exits)
    ->  update_room(Desc, Exits),
        format('Started in room: ~w~n', [Desc])
    ;   format('Failed to parse initial look~n', [])
    ),
    
    % Основной цикл
    bot_loop(Stream).

% Удаление элемента из списка
delete([], _, []).
delete([X|Xs], X, Ys) :- delete(Xs, X, Ys).
delete([X|Xs], Y, [X|Ys]) :- X \= Y, delete(Xs, Y, Ys).