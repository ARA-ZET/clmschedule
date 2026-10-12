import '../models/company.dart';
import '../models/job_list_item.dart';
import '../providers/company_provider.dart';
import '../providers/job_type_provider.dart';

/// Which Zoho Books organisation a company, job type or job bills through.
///
/// Junk & Stuff and Happy Sun are two organisations under one Zoho login, so
/// the same proxy and credentials serve both — only `organization_id` differs.
/// Every Zoho provider is keyed by the org id this returns, so the two sets of
/// customers, items and invoices never mix.
///
/// The id is read from `Company.providerConfig['organizationId']` when set, so
/// a further Zoho company needs no code change; the well-known ids below are
/// the fallback for the two companies that exist today.
class ZohoOrg {
  ZohoOrg._();

  static const String junkAndStuff = '747658013';
  static const String happySun = '936610938';

  /// `Company.providerConfig` key holding the organisation id.
  static const String configKey = 'organizationId';

  static String forCompany(Company? company) {
    final configured = company?.providerConfig[configKey]?.trim() ?? '';
    if (configured.isNotEmpty) return configured;
    return company?.id == Company.happySunId ? happySun : junkAndStuff;
  }

  static String forCompanyId(String companyId) {
    final company = CompanyProvider.instance?.getById(companyId);
    if (company != null) return forCompany(company);
    return companyId == Company.happySunId ? happySun : junkAndStuff;
  }

  /// Junk & Stuff when the job type is unknown — every Zoho invoice raised
  /// before Happy Sun had its own books lives there.
  static String forJobTypeId(String jobTypeId) {
    final type = JobTypeProvider.instance?.getJobTypeById(jobTypeId);
    return forCompanyId(type?.resolvedCompanyId ?? Company.junkAndStuffId);
  }

  static String forJob(JobListItem job) => forJobTypeId(job.jobTypeId);
}
