(ns mire.commands
  (:require [clojure.string :as str]
            [mire.rooms :as rooms]
            [mire.player :as player]))

(defn- move-between-refs
  "Move one instance of obj between from and to. Must call in a transaction."
  [obj from to]
  (alter from disj obj)
  (alter to conj obj))

;; Command functions

(defn look
  "Get a description of the surrounding environs and its contents."
  []
  (let [room @player/*current-room*
        known-exits (get @player/*known-exits* (:name room))
        ; Разыменовываем Ref с выходами
        exits-map @(:exits room)
        exits (keys exits-map)]
    (str (:desc room)
         "\nExits: "
         (str/join ", " 
                   (map (fn [dir]
                          (if-let [target (get known-exits dir)]
                            (str (name dir) " (to " (name target) ")")
                            (name dir)))
                        exits))
         "\n"
         (str/join "\n" (map #(str "There is " % " here.\n")
                             @(:items room))))))

(defn move
  "\"♬ We gotta get out of this place... ♪\" Give a direction."
  [direction]
  (dosync
   (let [current-room-val @player/*current-room* ; Получаем значение текущей комнаты
         dir-kw (keyword direction)
         ; Получаем Ref с выходами и разыменовываем его
         exits-map @(:exits current-room-val)
         target-name (exits-map dir-kw)
         target (@rooms/rooms target-name)]
     (if target
       (do
         ; Перемещаем игрока между комнатами
         (move-between-refs player/*name*
                            (:inhabitants current-room-val)
                            (:inhabitants target))
         (ref-set player/*current-room* target)
         ; Обновляем информацию о направлениях
         (commute player/*known-exits*
                  update (:name current-room-val) assoc dir-kw target-name)
         ; Добавляем новую комнату в посещенные
         (commute player/*visited-rooms* conj (:name target))
         ; Инициализируем выходы для новой комнаты
         (when (not (contains? @player/*known-exits* (:name target)))
           (commute player/*known-exits* assoc (:name target) {}))
         (look))
       "You can't go that way."))))


(defn grab
  "Pick something up."
  [thing]
  (dosync
   (if (rooms/room-contains? @player/*current-room* thing)
     (do (move-between-refs (keyword thing)
                            (:items @player/*current-room*)
                            player/*inventory*)
         (str "You picked up the " thing "."))
     (str "There isn't any " thing " here."))))

(defn discard
  "Put something down that you're carrying."
  [thing]
  (dosync
   (if (player/carrying? thing)
     (do (move-between-refs (keyword thing)
                            player/*inventory*
                            (:items @player/*current-room*))
         (str "You dropped the " thing "."))
     (str "You're not carrying a " thing "."))))

(defn inventory
  "See what you've got."
  []
  (str "You are carrying:\n"
       (str/join "\n" (seq @player/*inventory*))))

(defn detect
  "If you have the detector, you can see which room an item is in."
  [item]
  (if (@player/*inventory* :detector)
    (if-let [room (first (filter #((:items %) (keyword item))
                                 (vals @rooms/rooms)))]
      (str item " is in " (:name room))
      (str item " is not in any room."))
    "You need to be carrying the detector for that."))

(defn say
  "Say something out loud so everyone in the room can hear."
  [& words]
  (let [message (str/join " " words)
        ;; ANSI коды цветов
        name-color "\u001b[1;33m"  ; желтый (жирный)
        text-color "\u001b[1;37m"  ; белый (жирный)
        reset-color "\u001b[0m"    ; сброс
        formatted-msg (str name-color player/*name* ": " reset-color text-color message reset-color)]
    
    (doseq [inhabitant (disj @(:inhabitants @player/*current-room*)
                             player/*name*)]
      (binding [*out* (player/streams inhabitant)]
        (println formatted-msg)
        (print player/prompt)
        (flush)))
    
    formatted-msg))

(defn help
  "Show available commands and what they do."
  []
  (str/join "\n" (map #(str (key %) ": " (:doc (meta (val %))))
                      (dissoc (ns-publics 'mire.commands)
                              'execute 'commands))))

;; Command data

(def commands {"move" move,
               "north" (fn [] (move :north)),
               "south" (fn [] (move :south)),
               "east" (fn [] (move :east)),
               "west" (fn [] (move :west)),
               "grab" grab
               "discard" discard
               "inventory" inventory
               "detect" detect
               "look" look
               "say" say
               "help" help})

;; Command handling

(defn execute
  "Execute a command that is passed to us."
  [input]
  (try (let [[command & args] (.split input " +")]
         (apply (commands command) args))
       (catch Exception e
         (.printStackTrace e (new java.io.PrintWriter *err*))
         "You can't do that!")))
