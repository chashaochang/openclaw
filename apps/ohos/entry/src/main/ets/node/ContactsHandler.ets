/**
 * Contacts invoke handler: read contacts and locally filter to match Android search behavior.
 */
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import contact from '@ohos.contact';
import type { InvokeErrorShape, InvokeResult } from '../gateway/GatewaySession';

const DEFAULT_CONTACTS_LIMIT = 25;

type JsonValue = object | string | number | boolean | null | undefined;

interface ContactsSearchRequest {
  query: string | null;
  limit: number;
}

interface ContactsAddRequest {
  givenName: string | null;
  familyName: string | null;
  organizationName: string | null;
  displayName: string | null;
  phoneNumbers: string[];
  emails: string[];
}

interface ContactNameShape {
  fullName: string;
  givenName?: string;
  familyName?: string;
}

interface ContactOrganizationShape {
  name: string;
}

interface ContactPhoneShape {
  phoneNumber: string;
}

interface ContactEmailShape {
  email: string;
}

interface ContactShape {
  id?: number;
  key?: string;
  name?: ContactNameShape;
  organization?: ContactOrganizationShape;
  phoneNumbers?: ContactPhoneShape[];
  emails?: ContactEmailShape[];
}

interface ContactRecord {
  identifier: string;
  displayName: string;
  givenName: string;
  familyName: string;
  organizationName: string;
  phoneNumbers: string[];
  emails: string[];
}

function invokeErr(code: string, message: string): InvokeResult {
  const error: InvokeErrorShape = { code, message };
  return { ok: false, payloadJson: null, error };
}

function invokeOk(payloadJson: string): InvokeResult {
  return { ok: true, payloadJson, error: null };
}

function clampLimit(limit: number): number {
  return Math.max(1, Math.min(200, Math.floor(limit)));
}

function dedupeStrings(values: string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (let i = 0; i < values.length; i++) {
    const value = values[i];
    if (seen.has(value)) {
      continue;
    }
    seen.add(value);
    out.push(value);
  }
  return out;
}

export class ContactsHandler {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async handleContactsSearch(paramsJson: string | null): Promise<InvokeResult> {
    if (!this.hasPermission(['ohos.permission.READ_CONTACTS'])) {
      return invokeErr(
        'CONTACTS_PERMISSION_REQUIRED',
        'CONTACTS_PERMISSION_REQUIRED: grant Contacts permission',
      );
    }

    const request = this.parseSearchRequest(paramsJson);
    if (request === null) {
      return invokeErr('INVALID_REQUEST', 'INVALID_REQUEST: expected JSON object');
    }

    try {
      const contacts = await this.searchContacts(request);
      return invokeOk(JSON.stringify({ contacts }));
    } catch (error) {
      const message = this.errorMessage(error);
      return invokeErr('CONTACTS_UNAVAILABLE', `CONTACTS_UNAVAILABLE: ${message}`);
    }
  }

  async handleContactsAdd(paramsJson: string | null): Promise<InvokeResult> {
    if (!this.hasPermission(['ohos.permission.WRITE_CONTACTS'])) {
      return invokeErr(
        'CONTACTS_PERMISSION_REQUIRED',
        'CONTACTS_PERMISSION_REQUIRED: grant Contacts permission',
      );
    }

    const request = this.parseAddRequest(paramsJson);
    if (request === null) {
      return invokeErr('INVALID_REQUEST', 'INVALID_REQUEST: expected JSON object');
    }

    const hasName = !!(request.givenName || request.familyName || request.displayName);
    const hasOrg = !!request.organizationName;
    const hasDetails = request.phoneNumbers.length > 0 || request.emails.length > 0;
    if (!hasName && !hasOrg && !hasDetails) {
      return invokeErr(
        'CONTACTS_INVALID',
        'CONTACTS_INVALID: include a name, organization, phone, or email',
      );
    }

    try {
      const created = await this.addContact(request);
      return invokeOk(JSON.stringify({ contact: created }));
    } catch (error) {
      const message = this.errorMessage(error);
      return invokeErr('CONTACTS_UNAVAILABLE', `CONTACTS_UNAVAILABLE: ${message}`);
    }
  }

  private hasPermission(permissionNames: Permissions[]): boolean {
    const atManager = abilityAccessCtrl.createAtManager();
    const tokenId = this.context.applicationInfo.accessTokenId;
    for (let i = 0; i < permissionNames.length; i++) {
      try {
        const status = atManager.checkAccessTokenSync(tokenId, permissionNames[i]);
        if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          return true;
        }
      } catch {
        // Ignore unsupported permission names on some builds.
      }
    }
    return false;
  }

  private parseSearchRequest(paramsJson: string | null): ContactsSearchRequest | null {
    if (!paramsJson || paramsJson.trim().length === 0) {
      return {
        query: null,
        limit: DEFAULT_CONTACTS_LIMIT,
      };
    }
    try {
      const root = JSON.parse(paramsJson) as Record<string, JsonValue>;
      const queryRaw = root['query'];
      const limitRaw = root['limit'];
      const query = typeof queryRaw === 'string' ? queryRaw.trim() : '';
      const limit = typeof limitRaw === 'number' && Number.isFinite(limitRaw)
        ? clampLimit(limitRaw)
        : DEFAULT_CONTACTS_LIMIT;
      return {
        query: query.length > 0 ? query : null,
        limit,
      };
    } catch {
      return null;
    }
  }

  private parseAddRequest(paramsJson: string | null): ContactsAddRequest | null {
    try {
      const root = JSON.parse(paramsJson ?? '') as Record<string, JsonValue>;
      return {
        givenName: this.trimString(root['givenName']),
        familyName: this.trimString(root['familyName']),
        organizationName: this.trimString(root['organizationName']),
        displayName: this.trimString(root['displayName']),
        phoneNumbers: this.stringArray(root['phoneNumbers']),
        emails: this.stringArray(root['emails']).map((item) => item.toLowerCase()),
      };
    } catch {
      return null;
    }
  }

  private async searchContacts(request: ContactsSearchRequest): Promise<ContactRecord[]> {
    const attrs = new contact.ContactAttributes();
    attrs.attributes = [
      contact.Attribute.ATTR_NAME,
      contact.Attribute.ATTR_ORGANIZATION,
      contact.Attribute.ATTR_PHONE,
      contact.Attribute.ATTR_EMAIL,
    ];
    const contacts = await contact.queryContacts(this.context, undefined, attrs) as ContactShape[];
    const rows: ContactRecord[] = [];
    for (let i = 0; i < contacts.length; i++) {
      const mapped = this.mapContact(contacts[i]);
      if (mapped === null) {
        continue;
      }
      if (!this.matchesQuery(mapped, request.query)) {
        continue;
      }
      rows.push(mapped);
    }
    rows.sort((a, b) => a.displayName.localeCompare(b.displayName));
    if (rows.length <= request.limit) {
      return rows;
    }
    return rows.slice(0, request.limit);
  }

  private async addContact(request: ContactsAddRequest): Promise<ContactRecord> {
    const created = new contact.Contact();
    created.contactAttributes = new contact.ContactAttributes();
    created.contactAttributes.attributes = [
      contact.Attribute.ATTR_NAME,
      contact.Attribute.ATTR_ORGANIZATION,
      contact.Attribute.ATTR_PHONE,
      contact.Attribute.ATTR_EMAIL,
    ];
    if (request.givenName || request.familyName || request.displayName) {
      const name = new contact.Name();
      name.givenName = request.givenName ?? undefined;
      name.familyName = request.familyName ?? undefined;
      name.fullName = this.resolveDisplayName(request);
      created.name = name;
    }
    if (request.organizationName) {
      const organization = new contact.Organization();
      organization.name = request.organizationName;
      created.organization = organization;
    }
    if (request.phoneNumbers.length > 0) {
      created.phoneNumbers = request.phoneNumbers.map((value) => {
        const phone = new contact.PhoneNumber();
        phone.phoneNumber = value;
        phone.labelId = contact.PhoneNumber.NUM_MOBILE;
        return phone;
      });
    }
    if (request.emails.length > 0) {
      created.emails = request.emails.map((value) => {
        const email = new contact.Email();
        email.email = value;
        email.labelId = contact.Email.EMAIL_HOME;
        return email;
      });
    }
    const contactId = await contact.addContact(this.context, created);
    return {
      identifier: String(contactId),
      displayName: this.resolveDisplayName(request),
      givenName: request.givenName ?? '',
      familyName: request.familyName ?? '',
      organizationName: request.organizationName ?? '',
      phoneNumbers: request.phoneNumbers,
      emails: request.emails,
    };
  }

  private mapContact(raw: ContactShape): ContactRecord | null {
    const givenName = (raw.name?.givenName ?? '').trim();
    const familyName = (raw.name?.familyName ?? '').trim();
    const fullName = (raw.name?.fullName ?? '').trim();
    const displayName = fullName || [givenName, familyName].filter((item) => item.length > 0).join(' ').trim() || '(unnamed)';
    const organizationName = (raw.organization?.name ?? '').trim();
    const phones = this.normalizePhones(raw.phoneNumbers);
    const emails = this.normalizeEmails(raw.emails);
    const identifier = this.contactIdentifier(raw, displayName, phones, emails);
    if (identifier.length === 0) {
      return null;
    }
    return {
      identifier,
      displayName,
      givenName,
      familyName,
      organizationName,
      phoneNumbers: phones,
      emails,
    };
  }

  private normalizePhones(items: ContactPhoneShape[] | undefined): string[] {
    if (!items || items.length === 0) {
      return [];
    }
    const out: string[] = [];
    for (let i = 0; i < items.length; i++) {
      const value = (items[i].phoneNumber ?? '').trim();
      if (value.length > 0) {
        out.push(value);
      }
    }
    return dedupeStrings(out);
  }

  private normalizeEmails(items: ContactEmailShape[] | undefined): string[] {
    if (!items || items.length === 0) {
      return [];
    }
    const out: string[] = [];
    for (let i = 0; i < items.length; i++) {
      const value = (items[i].email ?? '').trim().toLowerCase();
      if (value.length > 0) {
        out.push(value);
      }
    }
    return dedupeStrings(out);
  }

  private stringArray(raw: JsonValue): string[] {
    if (!Array.isArray(raw)) {
      return [];
    }
    const values: string[] = [];
    for (let i = 0; i < raw.length; i++) {
      const value = this.trimString(raw[i]);
      if (value) {
        values.push(value);
      }
    }
    return dedupeStrings(values);
  }

  private trimString(raw: JsonValue): string | null {
    if (typeof raw !== 'string') {
      return null;
    }
    const value = raw.trim();
    return value.length > 0 ? value : null;
  }

  private resolveDisplayName(request: ContactsAddRequest): string {
    const preferred = request.displayName ?? '';
    if (preferred.length > 0) {
      return preferred;
    }
    const joined = [request.givenName ?? '', request.familyName ?? '']
      .filter((item) => item.length > 0)
      .join(' ')
      .trim();
    if (joined.length > 0) {
      return joined;
    }
    if (request.organizationName) {
      return request.organizationName;
    }
    if (request.phoneNumbers.length > 0) {
      return request.phoneNumbers[0];
    }
    if (request.emails.length > 0) {
      return request.emails[0];
    }
    return '(unnamed)';
  }

  private contactIdentifier(
    raw: ContactShape,
    displayName: string,
    phones: string[],
    emails: string[],
  ): string {
    if (typeof raw.id === 'number' && Number.isFinite(raw.id)) {
      return String(raw.id);
    }
    const key = (raw.key ?? '').trim();
    if (key.length > 0) {
      return key;
    }
    if (phones.length > 0) {
      return `phone:${phones[0]}`;
    }
    if (emails.length > 0) {
      return `email:${emails[0]}`;
    }
    return `name:${displayName}`;
  }

  private matchesQuery(row: ContactRecord, query: string | null): boolean {
    if (!query) {
      return true;
    }
    const needle = query.trim().toLowerCase();
    if (needle.length === 0) {
      return true;
    }
    const haystacks: string[] = [
      row.displayName,
      row.givenName,
      row.familyName,
      row.organizationName,
    ];
    for (let i = 0; i < row.phoneNumbers.length; i++) {
      haystacks.push(row.phoneNumbers[i]);
      haystacks.push(row.phoneNumbers[i].replace(/[\s\-()]/g, ''));
    }
    for (let i = 0; i < row.emails.length; i++) {
      haystacks.push(row.emails[i]);
    }
    for (let i = 0; i < haystacks.length; i++) {
      const value = haystacks[i].trim().toLowerCase();
      if (value.length > 0 && value.includes(needle)) {
        return true;
      }
    }
    return false;
  }

  private errorMessage(error: JsonValue): string {
    if (error instanceof Error) {
      return error.message.trim().length > 0 ? error.message : 'contacts query failed';
    }
    if (typeof error === 'object' && error !== null) {
      const root = error as Record<string, JsonValue>;
      const message = typeof root['message'] === 'string' ? root['message'].trim() : '';
      if (message.length > 0) {
        return message;
      }
      const code = root['code'];
      if (typeof code === 'number' || typeof code === 'string') {
        return String(code);
      }
    }
    return 'contacts query failed';
  }
}
