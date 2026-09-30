import Foundation

/// Frequent English words. A vocabulary entry whose spoken form is one of these replaces the word
/// in every dictation, so Settings asks the user to confirm before saving it.
enum CommonEnglishWords {
    static func contains(_ word: String) -> Bool {
        words.contains(word.lowercased())
    }

    private static let words: Set<String> = Set(
        """
        a able about above accept across act action actually add after again against age ago agree
        ahead air all allow almost alone along already also although always am among amount an and
        animal another answer any anyone anything appear apply are area arm around arrive art as ask
        at attack away baby back bad bag ball bank bar base be bear beat beautiful because become bed
        been before begin behind believe below best better between big bill bit black blood blue board
        boat body book born both box boy break bring brother build building business but buy by call
        came camera can car card care carry case cash cat catch cause cell center certain chair chance
        change charge check child choice choose church city claim class clear close cold color come
        common company compare complete computer consider continue control cook cool copy cost could
        count country couple course court cover create cross cup current cut dark data date daughter
        day dead deal dear death decide deep degree deliver design detail develop did die difference
        different dinner direction do doctor does dog door double down draw dream dress drink drive
        drop dry during each early earth east easy eat edge effect eight either else end enjoy enough
        enter even evening event ever every everyone everything exactly example expect experience
        explain eye face fact fail fair fall family far farm fast father fear feel feet few field
        fight figure file fill final find fine finish fire firm first fish five floor fly follow food
        foot for force foreign forget form forward four free fresh friend from front full fun game
        garden general get girl give glass go goal god gold gone good got government great green
        ground group grow guess gun guy hair half hall hand hang happen happy hard has hat have he head
        health hear heart heat heavy held hello help her here high hill him his hit hold hole home hope
        horse hospital hot hotel hour house how however huge human hundred husband I idea if image
        important in include increase indeed inside instead interest into iron is island issue it item
        its job join joke just keep key kid kill kind king kitchen knew know land language large last
        late later laugh law lay lead learn least leave left leg less let letter level lie life light
        like line list listen little live long look lose loss lost lot loud love low lunch machine made
        mail main major make man manage many mark market match matter may maybe me mean meet member
        memory men message middle might mile milk mind mine minute miss model moment money month more
        morning most mother mouth move much music must my name nation near need never new news next
        nice night nine no none nor north not note nothing notice now number of off offer office often
        oh oil ok okay old on once one only open or order other our out outside over own page paint
        pair paper parent park part party pass past pay peace people perhaps period person phone pick
        picture piece place plan plant play please point police poor position possible post pound
        power present press pretty price problem produce program pull push put question quick quite
        race rain raise ran rate rather reach read ready real reason receive record red remember report
        rest return rich ride right ring rise river road rock role room rose round rule run safe said
        sale same save saw say school sea season seat second see seem sell send sense sent serve set
        seven several shall share she ship shop short should show side sign simple since sing sink
        sister sit six size skin sleep small smile snow so some someone something sometimes son song
        soon sort sound south space speak special spend spring square staff stage stand star start
        state stay step still stock stop store story street strong student study stuff style such
        suddenly summer sun support sure surface system table take talk tall tax tea teach team tell
        ten term test than thank that the their them then there these they thing think third this
        those though thought thousand three through throw time to today together told tomorrow tone
        tonight too took top total touch toward town trade train travel tree trial trip trouble true
        try turn two type under understand until up upon us use usual very view visit voice wait walk
        wall want war warm was wash watch water way we wear weather week weight well went were west
        what whatever wheel when where whether which while white who whole whom whose why wide wife
        will win wind window winter wish with within without woman women won wonder wood word work
        world worry would write wrong yard yeah year yes yesterday yet you young your
        """.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
    )
}
