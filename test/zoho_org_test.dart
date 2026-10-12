import 'package:clmschedule/models/company.dart';
import 'package:clmschedule/utils/zoho_org.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ZohoOrg.forCompany', () {
    test('Junk & Stuff and Happy Sun fall back to their own organisations', () {
      expect(
        ZohoOrg.forCompany(
            const Company(id: Company.junkAndStuffId, name: 'J&S')),
        ZohoOrg.junkAndStuff,
      );
      expect(
        ZohoOrg.forCompany(const Company(id: Company.happySunId, name: 'HS')),
        ZohoOrg.happySun,
      );
    });

    test('a configured organisation id wins over the fallback', () {
      expect(
        ZohoOrg.forCompany(const Company(
          id: Company.happySunId,
          name: 'HS',
          providerConfig: {ZohoOrg.configKey: ' 123 '},
        )),
        '123',
      );
    });

    test('an unknown company never resolves to Happy Sun', () {
      expect(ZohoOrg.forCompany(null), ZohoOrg.junkAndStuff);
      expect(ZohoOrg.forCompanyId('somethingElse'), ZohoOrg.junkAndStuff);
    });
  });
}
