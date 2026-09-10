/* Generated from ../../schema/policy-dump.schema.json by gen-types.mjs. DO NOT EDIT. */

/**
 * The ONLY artifact that leaves the owner's device. Anything absent here is absent by design, not by omission — see ../design/architecture.md section 2.
 */
export interface PolicyDump {
  v: 1;
  slug: string;
  generated: string;
  /**
   * After this the service stops serving the dump, so a device that goes quiet cannot leave stale availability up forever.
   */
  expires: string;
  display: {
    /**
     * The single identifying field in the whole document, chosen by the owner in the knowledge that it is public.
     */
    name: string;
    blurb?: string;
    /**
     * IANA zone, for showing the owner's local time beside the requester's.
     */
    tz: string;
  };
  meeting: {
    minutes: number;
    /**
     * Set by the owner, never by the requester — stranger-supplied text does not belong in someone's calendar title.
     */
    title: string;
    location?: string | null;
  };
  /**
   * Offerable slots as UTC instants. NOT free/busy: the absence of a slot may be a meeting or may be policy, and the page cannot tell which.
   *
   * @maxItems 500
   */
  slots: {
    s: string;
    e: string;
  }[];
  /**
   * Added by the SERVICE on the way out, never by the device: the start of every slot somebody has asked for and not yet been answered on (architecture 4b). A held slot renders as 'just asked for' rather than vanishing. Privacy-neutral - a hold is already visible as a 409 to anyone who asks - and the service refuses an uploaded dump that carries it. Matt, 10 Sept 2026.
   *
   * @maxItems 500
   */
  held?: string[];
}

/** One offer, as the schema spells it: start and end, ISO-8601 UTC. */
export type Slot = PolicyDump['slots'][number];
