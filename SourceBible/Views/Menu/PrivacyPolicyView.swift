// PrivacyPolicyView.swift
// SourceBible
//
// In-app Privacy Policy screen (Menu → Statistics → Privacy Policy). Same style
// as AboutView: long-form copy held inline and picked by `appLanguage` rather
// than routed through xcstrings. Satisfies App Review 5.1.1(i) — the privacy
// policy is accessible within the app in an easily-accessible place. The same
// text is mirrored on the hosted page used for the App Store Connect URL.

import SwiftUI

struct PrivacyPolicyView: View {
    @AppStorage(AppStorageKeys.colorTheme) private var colorThemeRaw = ColorTheme.paper.rawValue
    // Дефолт `@AppStorage` спрацьовує, поки ключа НЕМА — а він пишеться лише
    // коли людина відкриє пікер мови. Жорсткий "en" тут означав, що на
    // українському телефоні цей екран був англійським, хоч решта інтерфейсу
    // (через свізл бандла) — українська. `resolved` дає ту саму мову, що й свізл.
    @AppStorage(AppStorageKeys.appLanguage) private var appLanguage: String = AppLanguage.resolved

    private var colorTheme: ColorTheme { ColorTheme(rawValue: colorThemeRaw) ?? .paper }
    private var uk: Bool { appLanguage == "uk" }

    /// A titled section: bold heading + body paragraph, matching AboutView spacing.
    private struct Section: Identifiable {
        let id = UUID()
        let title: String
        let body: String
    }

    var body: some View {
        ZStack {
            colorTheme.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {

                    Text(uk ? "Чинна з 17 липня 2026" : "Effective 17 July 2026")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text(uk
                         ? "Source Bible створено так, щоб зберігати ваші дані приватними. Більшість того, що ви створюєте, залишається на вашому пристрої, а аналітика збирається лише за вашою згодою."
                         : "Source Bible is built to keep your data private. Most of what you create stays on your device, and analytics are collected only if you agree to them.")
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(section.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // Contact
                    VStack(alignment: .leading, spacing: 6) {
                        Text(uk ? "Контакти" : "Contact")
                            .font(.headline)
                        Link("ivan.khoma@gmail.com",
                             destination: URL(string: "mailto:ivan.khoma@gmail.com")!)
                            .foregroundStyle(.appBlue)
                    }
                    .padding(.top, 4)
                }
                .padding(20)
            }
        }
        .navigationTitle("menu.privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Content

    private var sections: [Section] {
        if uk {
            return [
                Section(title: "Хто ми",
                        body: "Застосунок Source Bible надає Ivan Khoma. З питань приватності пишіть на ivan.khoma@gmail.com."),
                Section(title: "Дані, що зберігаються на пристрої",
                        body: "Ваші нотатки, виділення, закладки, позиція читання та налаштування зберігаються локально на вашому пристрої всередині застосунку. Вони не завантажуються до нас і не синхронізуються з жодним сервером."),
                Section(title: "Аналітика (за бажанням, лише за вашою згодою)",
                        body: "Якщо ви ввімкнете аналітику, ми використовуємо Mixpanel, щоб розуміти, як використовується застосунок. Ми фіксуємо, що певні дії відбулися — наприклад, що ви створили нотатку, виділення чи закладку, перемкнули переклад або виконали пошук (і скільки результатів він дав), — але НЕ вміст ваших нотаток і НЕ текст ваших пошукових запитів. Разом із цим збирається випадково згенерований ідентифікатор інсталяції та стандартна технічна інформація (модель пристрою, версія ОС, версія застосунку та приблизне місцезнаходження, як-от місто чи країна, визначене за IP-адресою). Сам застосунок не запитує доступу до місцезнаходження пристрою. Якщо ви не даєте згоди або вимикаєте аналітику, ці події не збираються."),
                Section(title: "Треті сторони",
                        body: "Наведені вище аналітичні дані ми передаємо лише Mixpanel як нашому постачальнику аналітики, який зобов’язаний захищати їх на тому ж рівні, що описаний тут. Донати обробляє Apple через внутрішні покупки — ми ніколи не отримуємо даних вашої картки чи платежу."),
                Section(title: "Чого ми не робимо",
                        body: "Ми не вимагаємо акаунту й не просимо ваше ім’я чи email. Ми не показуємо реклами, не продаємо ваші дані й не відстежуємо вас в інших застосунках чи на вебсайтах."),
                Section(title: "Зберігання та видалення",
                        body: "Дані на вашому пристрої залишаються на пристрої й видаляються, коли ви видаляєте застосунок. Ми не зберігаємо для вас акаунту, імені чи email, тож у нас немає персонального профілю, який можна було б видалити. Аналітичні події псевдонімні — пов’язані лише з випадковим ідентифікатором інсталяції, а не з вашою особою — і видаляються Mixpanel приблизно через два роки. Вимкнення аналітики одразу припиняє будь-яке подальше збирання."),
                Section(title: "Ваш вибір і права",
                        body: "Ви можете вмикати чи вимикати аналітику в застосунку будь-коли; вимкнення одразу припиняє збирання. Оскільки ми не зберігаємо даних, що вас ідентифікують, немає персонального акаунта, до якого можна отримати доступ чи який можна видалити. Якщо у вас є запитання щодо даних — напишіть нам."),
                Section(title: "Діти",
                        body: "Застосунок призначений для широкої аудиторії та підходить для будь-якого віку. Ми свідомо не збираємо персональних даних дітей, і для користування не потрібні жодні персональні дані чи акаунт."),
                Section(title: "Безпека",
                        body: "Ми вживаємо розумних заходів для захисту даних. Дані на вашому пристрої також захищені власними засобами безпеки пристрою."),
                Section(title: "Зміни",
                        body: "Ми можемо оновлювати цю політику; дата вгорі змінюватиметься."),
            ]
        }
        return [
            Section(title: "Who we are",
                    body: "Source Bible is provided by Ivan Khoma. If you have any questions about privacy, email us at ivan.khoma@gmail.com."),
            Section(title: "Data stored on your device",
                    body: "Your notes, highlights, bookmarks, reading position and app settings are stored locally on your device inside the app. They are not uploaded to us or synced to any server."),
            Section(title: "Analytics (optional, only with your consent)",
                    body: "If you enable analytics, we use Mixpanel to understand how the app is used. We record that certain actions happened — for example that you created a note, highlight or bookmark, switched translations, or ran a search (and how many results it returned) — but NOT the content of your notes and NOT the text of your searches. Alongside this we collect a randomly generated app-install identifier and standard technical information (device model, OS version, app version, and approximate location, such as city or country, derived from your IP address). The app itself does not ask for access to your device location. If you do not consent, or turn analytics off, these events are not collected."),
            Section(title: "Third parties",
                    body: "We share the analytics data above only with Mixpanel, acting as our analytics provider, which is required to protect it to the same standard described here. Donations are processed by Apple through in-app purchase — we never receive your card or payment details."),
            Section(title: "What we do not do",
                    body: "We do not require an account or ask for your name or email. We show no ads, do not sell your data, and do not track you across other apps or websites."),
            Section(title: "Retention and deletion",
                    body: "Data on your device stays on your device and is removed when you delete the app. We do not hold an account, name, or email for you, so there is no personal profile for us to delete. Analytics events are pseudonymous — linked only to a random install identifier, not to your identity — and are removed by Mixpanel after about two years. Turning analytics off stops any further collection at once."),
            Section(title: "Your choices and rights",
                    body: "You can enable or disable analytics inside the app at any time; turning it off stops collection immediately. Because we do not hold information that identifies you, there is no personal account for us to access or delete. If you have any questions about your data, contact us."),
            Section(title: "Children",
                    body: "The app is intended for a general audience and is suitable for all ages. We do not knowingly collect personal data from children, and no personal information or account is required to use it."),
            Section(title: "Security",
                    body: "We use reasonable measures to protect data. Data stored on your device is also protected by your device’s own security."),
            Section(title: "Changes",
                    body: "We may update this policy; the date above will change."),
        ]
    }
}

#if DEBUG
#Preview {
    NavigationStack { PrivacyPolicyView() }
}
#endif
