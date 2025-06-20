(ns mire.player)

(def ^:dynamic *current-room*)
(def ^:dynamic *inventory*)
(def ^:dynamic *name*)
(def ^:dynamic *visited-rooms*)   ; Множество посещенных комнат
(def ^:dynamic *known-exits*)     ; Карта исследованных выходов {room {direction target}}

(def prompt "> ")
(def streams (ref {}))

(defn carrying? [thing]
  (some #{(keyword thing)} @*inventory*))
