import Foundation

// ============================================================================
//  Ручки раздела «Управление». Пути — как в routes/seller_settings.php,
//  routes/seller_marketing.php и routes/seller_import.php.
//
//  Выгрузки и QR приходят файлом, а не JSON-конвертом, поэтому идут через
//  downloadFile(): он кладёт ответ во временный файл и понимает случай, когда
//  вместо файла сервер вернул {ok:false,error} — тогда покажется текст ошибки,
//  а не битый XLSX.
// ============================================================================

extension API {

    // ── Вакансии ─────────────────────────────────────────────────────────
    func vacancies() async throws -> [Vacancy] {
        try await get("api/seller/vacancies", as: [Vacancy].self)
    }

    /// Тело одинаковое у создания и правки — сервер использует один saveVacancy().
    private func vacancyBody(title: String, category: VacancyCategory, description: String,
                             requirements: String, conditions: String, schedule: String,
                             salaryFrom: Decimal?, salaryTo: Decimal?,
                             employment: VacancyEmployment, experience: VacancyExperience,
                             address: String, status: VacancyStatus) -> [String: Any?] {
        [
            "title": title,
            "category": category.rawValue,
            "description": description.isEmpty ? nil : description,
            "requirements": requirements.isEmpty ? nil : requirements,
            "conditions": conditions.isEmpty ? nil : conditions,
            "schedule": schedule.isEmpty ? nil : schedule,
            "salary_from": salaryFrom.map { "\($0)" },
            "salary_to": salaryTo.map { "\($0)" },
            "employment_type": employment.rawValue,
            "experience": experience.rawValue,
            "address": address.isEmpty ? nil : address,
            "status": status.rawValue,
        ]
    }

    func createVacancy(title: String, category: VacancyCategory, description: String,
                       requirements: String, conditions: String, schedule: String,
                       salaryFrom: Decimal?, salaryTo: Decimal?,
                       employment: VacancyEmployment, experience: VacancyExperience,
                       address: String, status: VacancyStatus) async throws -> Int {
        let ack = try await post("api/seller/vacancies",
                                 body: vacancyBody(title: title, category: category,
                                                   description: description, requirements: requirements,
                                                   conditions: conditions, schedule: schedule,
                                                   salaryFrom: salaryFrom, salaryTo: salaryTo,
                                                   employment: employment, experience: experience,
                                                   address: address, status: status),
                                 as: IdAck.self)
        return ack.id ?? 0
    }

    /// Правка: пустое поле должно стирать значение. nil makeRequest выбрасывает
    /// из тела, сервер оставлял старое — «по договорённости» не ставилось,
    /// адрес и требования не стирались.
    private func clearingEmpty(_ body: [String: Any?]) -> [String: Any?] {
        var b = body
        for k in ["description", "requirements", "conditions", "schedule", "address"] {
            if let v = b[k], v == nil { b[k] = "" }
        }
        for k in ["salary_from", "salary_to"] {
            if let v = b[k], v == nil { b[k] = NSNull() }
        }
        return b
    }

    func updateVacancy(id: Int, title: String, category: VacancyCategory, description: String,
                       requirements: String, conditions: String, schedule: String,
                       salaryFrom: Decimal?, salaryTo: Decimal?,
                       employment: VacancyEmployment, experience: VacancyExperience,
                       address: String, status: VacancyStatus) async throws {
        _ = try await put("api/seller/vacancies/\(id)",
                          body: clearingEmpty(vacancyBody(title: title, category: category,
                                            description: description, requirements: requirements,
                                            conditions: conditions, schedule: schedule,
                                            salaryFrom: salaryFrom, salaryTo: salaryTo,
                                            employment: employment, experience: experience,
                                            address: address, status: status)),
                          as: Phase2BoolAck.self)
    }

    func deleteVacancy(id: Int) async throws {
        _ = try await delete("api/seller/vacancies/\(id)", as: Phase2BoolAck.self)
    }

    func vacancyApplications(vacancyId: Int) async throws -> [JobApplication] {
        try await get("api/seller/vacancies/\(vacancyId)/applications", as: [JobApplication].self)
    }

    /// Сервер принимает new|viewed|invited|rejected, всё прочее считает viewed.
    func setApplicationStatus(id: Int, status: ApplicationStatus) async throws -> String {
        let ack = try await post("api/seller/applications/\(id)/status",
                                 body: ["status": status.rawValue], as: StatusAck.self)
        return ack.status ?? status.rawValue
    }

    // ── Подарочные карты ─────────────────────────────────────────────────
    func giftCards() async throws -> [GiftCard] {
        try await get("api/seller/giftcards", as: [GiftCard].self)
    }

    /// expiresAt — «YYYY-MM-DD HH:MM:SS» либо nil (бессрочная).
    /// keys — ключи окна выпуска карты (IdempotencyKeys.form()).
    func createGiftCard(amount: Decimal, expiresAt: String?, keys: IdempotencyKeys? = nil) async throws -> GiftCardCreateAck {
        // Ключ повтора (сервер: giftcards.create): «Выпустить» после обрыва — без второй карты.
        try await postKeyed("api/seller/giftcards",
                            body: ["amount": "\(amount)", "expires_at": expiresAt],
                            as: GiftCardCreateAck.self, keys: keys)
    }

    /// Сервер не удаляет карту, а переводит её в expired — история покупок цела.
    func deactivateGiftCard(id: Int) async throws {
        _ = try await delete("api/seller/giftcards/\(id)", as: Phase2BoolAck.self)
    }

    // ── Выгрузки ─────────────────────────────────────────────────────────
    /// key: products | clients | orders | stock | ingredients | 1c | template.
    func exportData(_ key: String, fallbackName: String) async throws -> URL {
        try await downloadFile("api/seller/export/\(key)", fallbackName: fallbackName)
    }

    // ── QR витрины ───────────────────────────────────────────────────────
    /// SVG — для печати (вектор), PNG — для мессенджеров.
    func shopQrFile(svg: Bool, size: Int = 1024) async throws -> URL {
        svg
            ? try await downloadFile("api/seller/marketing/qr.svg", fallbackName: "qr.svg")
            : try await downloadFile("api/seller/marketing/qr.png",
                                     query: ["size": String(size)], fallbackName: "qr.png")
    }

    // ── Тип и режим организации ──────────────────────────────────────────
    func setOrgType(_ type: OrgType) async throws -> String {
        let ack = try await post("api/seller/settings/type", body: ["type": type.rawValue], as: OrgTypeAck.self)
        return ack.type ?? type.rawValue
    }

    func setOrgMode(_ mode: OrgMode) async throws -> String {
        let ack = try await post("api/seller/settings/mode", body: ["mode": mode.rawValue], as: OrgModeAck.self)
        return ack.mode ?? mode.rawValue
    }
}
